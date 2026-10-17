#!/usr/bin/env python3
"""Builds the shop catalog the app ranks on the device (plan: project plans/shopping-israel.md).

For each store in stores.json: robots.txt -> sitemaps -> product pages, reading the JSON-LD
Product / ProductGroup and Open Graph data every shop publishes for search engines. Shopify stores
are read from /products.json instead. Only raw fields are stored; the app maps them to its taxonomy
through ProductPageMetadataService.makeProduct / ProductFieldMapper, so mapping lives in one place.

Runs are incremental: pass the previous catalog and each run fetches new URLs first, then the
oldest ones, up to the store's page budget. Products whose URL left the sitemap are dropped.

Usage: python3 scripts/catalog/build_catalog.py --country IL --out out/il [--previous prev.json]
No third-party packages."""
import argparse
import gzip
import hashlib
import html
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

USER_AGENT = "WearItCatalogBot/0.1 (+https://111dd.github.io/WearIt/)"
TIMEOUT = 25
MAX_SITEMAPS = 60
DESCRIPTION_LIMIT = 400
IMAGE_LIMIT = 4
PRODUCT_SITEMAP_HINT = re.compile(r"product|prod|item|catalog", re.I)


def looks_like_product_sitemap(url):
    # "sitemap" itself contains "item", so match on the file name without it.
    name = urllib.parse.urlparse(url).path.rsplit("/", 1)[-1].lower().replace("sitemap", "")
    return bool(PRODUCT_SITEMAP_HINT.search(name))


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def iri_to_uri(url):
    """Hebrew paths ("/נשים/חולצות/...") must be percent-encoded before urllib sends them."""
    parts = urllib.parse.urlsplit(url)
    path = urllib.parse.quote(parts.path, safe="/%:@!$&'()*+,;=-._~")
    query = urllib.parse.quote(parts.query, safe="=&%:@!$'()*+,;/?-._~")
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc.encode("idna").decode("ascii"), path, query, parts.fragment))


def readable(url):
    """The URL as people read it, for pattern matching and gender hints."""
    return urllib.parse.unquote(url)


def fetch(url, accept="text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", data=None, content_type=None):
    url = iri_to_uri(url)
    headers = {
        "User-Agent": USER_AGENT,
        "Accept": accept,
        "Accept-Language": "he-IL,he;q=0.9,en;q=0.6",
        "Accept-Encoding": "gzip",
    }
    if content_type:
        headers["Content-Type"] = content_type
    request = urllib.request.Request(url, data=data, headers=headers)
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        body = response.read()
        if response.headers.get("Content-Encoding") == "gzip" or url.endswith(".gz"):
            try:
                body = gzip.decompress(body)
            except OSError:
                pass
        charset = response.headers.get_content_charset() or "utf-8"
        return body.decode(charset, errors="replace")


# MARK: - Sitemaps

def sitemap_locations(xml_text):
    """Returns (child sitemaps, page URLs) from a sitemap or sitemap index."""
    try:
        root = ET.fromstring(xml_text.encode("utf-8"))
    except ET.ParseError:
        return [], []
    tag = root.tag.split("}")[-1]
    locs = [el.text.strip() for el in root.iter() if el.tag.split("}")[-1] == "loc" and el.text]
    if tag == "sitemapindex":
        return locs, []
    # Image sitemap entries (<image:loc>) also end in "loc"; keep page URLs only.
    pages = []
    for url_el in root:
        for child in url_el:
            if child.tag.split("}")[-1] == "loc" and child.text:
                pages.append(child.text.strip())
                break
    return [], pages


def discover_product_urls(store, robots, log):
    base = store["base"].rstrip("/")
    queue = list(store.get("sitemaps") or robots.site_maps() or [f"{base}/sitemap.xml"])
    pattern = re.compile(store["productUrlPattern"]) if store.get("productUrlPattern") else None
    seen, pages = set(), []
    while queue and len(seen) < MAX_SITEMAPS:
        sitemap = queue.pop(0)
        if sitemap in seen:
            continue
        seen.add(sitemap)
        try:
            children, urls = sitemap_locations(fetch(sitemap, accept="application/xml,text/xml,*/*"))
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            log.append(f"sitemap failed {sitemap}: {error}")
            continue
        # Prefer product sitemaps when the index names them; otherwise walk everything.
        product_children = [c for c in children if looks_like_product_sitemap(c)]
        queue.extend(product_children or children)
        pages.extend(urls)
        time.sleep(store.get("delaySeconds", 1.0) / 2)
    if pattern:
        pages = [u for u in pages if pattern.search(readable(u))]
    exclude = re.compile(store["excludeUrlPattern"]) if store.get("excludeUrlPattern") else None
    if exclude:
        pages = [u for u in pages if not exclude.search(readable(u))]
    return list(dict.fromkeys(pages))


# MARK: - Page parsing

def json_ld_blocks(page):
    for match in re.finditer(r'<script[^>]+type=["\']application/ld\+json["\'][^>]*>(.*?)</script>', page, re.S | re.I):
        raw = match.group(1).strip()
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            try:
                data = json.loads(html.unescape(raw))
            except json.JSONDecodeError:
                continue
        yield from flatten_ld(data)


def flatten_ld(data):
    if isinstance(data, list):
        for item in data:
            yield from flatten_ld(item)
    elif isinstance(data, dict):
        if "@graph" in data:
            yield from flatten_ld(data["@graph"])
        else:
            yield data


def types_of(node):
    kind = node.get("@type")
    return set(kind) if isinstance(kind, list) else {kind}


def text(value):
    if value is None:
        return None
    if isinstance(value, dict):
        return text(value.get("name") or value.get("@value"))
    if isinstance(value, list):
        parts = [text(v) for v in value]
        return ", ".join(p for p in parts if p) or None
    value = html.unescape(re.sub(r"<[^>]+>", " ", str(value)))
    value = re.sub(r"\s+", " ", value).strip()
    return value or None


def images_of(value, page_url):
    if value is None:
        return []
    values = value if isinstance(value, list) else [value]
    urls = []
    for item in values:
        if isinstance(item, dict):
            item = item.get("contentUrl") or item.get("url")
        if isinstance(item, str) and item.strip():
            urls.append(urllib.parse.urljoin(page_url, item.strip()))
    return urls


def as_list(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def offer_facts(offers):
    """Price, currency and availability from Offer / AggregateOffer nodes."""
    price = currency = None
    available = None
    for offer in as_list(offers):
        if not isinstance(offer, dict):
            continue
        for key in ("price", "lowPrice"):
            if offer.get(key) not in (None, "") and price is None:
                try:
                    price = float(str(offer[key]).replace(",", ""))
                except ValueError:
                    pass
        spec = offer.get("priceSpecification")
        spec = spec[0] if isinstance(spec, list) and spec else spec
        spec = spec if isinstance(spec, dict) else {}
        if price is None and spec.get("price") is not None:
            try:
                price = float(str(spec["price"]).replace(",", ""))
            except ValueError:
                pass
        currency = currency or offer.get("priceCurrency") or spec.get("priceCurrency")
        availability = str(offer.get("availability") or "")
        if availability:
            in_stock = "InStock" in availability or "LimitedAvailability" in availability or "PreOrder" in availability
            available = bool(available) or in_stock
    return price, currency, available


def variant_sizes(variants):
    sizes, in_stock = [], []
    for variant in as_list(variants):
        if not isinstance(variant, dict):
            continue
        size = text(variant.get("size"))
        if not size:
            continue
        sizes.append(size)
        _, _, available = offer_facts(variant.get("offers"))
        if available:
            in_stock.append(size)
    return list(dict.fromkeys(sizes)), list(dict.fromkeys(in_stock))


def breadcrumb_path(nodes):
    for node in nodes:
        if "BreadcrumbList" in types_of(node):
            items = sorted(as_list(node.get("itemListElement")), key=lambda i: i.get("position", 0) if isinstance(i, dict) else 0)
            names = [text(i.get("name") or i.get("item")) for i in items if isinstance(i, dict)]
            names = [n for n in names if n and not n.startswith("http")]
            if names:
                return " > ".join(names)
    return None


def meta_content(page, prop):
    pattern = rf'<meta[^>]+(?:property|name)=["\']{re.escape(prop)}["\'][^>]*content=["\']([^"\']*)["\']'
    match = re.search(pattern, page, re.I) or re.search(
        rf'<meta[^>]+content=["\']([^"\']*)["\'][^>]*(?:property|name)=["\']{re.escape(prop)}["\']', page, re.I)
    return text(match.group(1)) if match else None


GENDER_WORDS = [
    ("kids", r"\b(kids?|children|boys?|girls?|baby|junior)\b|ילדים|ילדות|תינוק|בנים|בנות|נוער"),
    ("women", r"\b(women|womens|woman|female|ladies)\b|נשים|אישה|לנשים"),
    ("men", r"\b(men|mens|man|male)\b|גברים|לגבר|לגברים"),
]


def guess_gender(*hints):
    joined = " ".join(h for h in hints if h).lower()
    for gender, pattern in GENDER_WORDS:
        if re.search(pattern, joined):
            return gender
    return None


def parse_product_page(page, page_url):
    """Raw product fields from one page, or None if the page isn't a product."""
    nodes = list(json_ld_blocks(page))
    product = next((n for n in nodes if types_of(n) & {"Product", "ProductGroup"}), None)
    category_path = breadcrumb_path(nodes)
    og_type = (meta_content(page, "og:type") or "").lower()
    if product is None and "product" not in og_type:
        return None
    product = product or {}

    variants = product.get("hasVariant")
    sizes, in_stock_sizes = variant_sizes(variants)
    price, currency, available = offer_facts(product.get("offers"))
    if price is None and variants:
        price, currency, variant_available = offer_facts([o for v in as_list(variants) if isinstance(v, dict) for o in as_list(v.get("offers"))])
        available = available if available is not None else variant_available
    if price is None:
        amount = meta_content(page, "product:price:amount") or meta_content(page, "og:price:amount")
        try:
            price = float(amount.replace(",", "")) if amount else None
        except ValueError:
            price = None
        currency = currency or meta_content(page, "product:price:currency") or meta_content(page, "og:price:currency")
    if available is None:
        availability = (meta_content(page, "product:availability") or meta_content(page, "og:availability") or "").lower()
        available = ("in stock" in availability or "instock" in availability) if availability else None
    if sizes and available is None:
        available = bool(in_stock_sizes)
    if not sizes and product.get("size"):
        sizes = [s.strip() for s in (text(product.get("size")) or "").split(",") if s.strip()]

    original = meta_content(page, "product:original_price:amount")
    title = text(product.get("name")) or meta_content(page, "og:title")
    if not title:
        return None
    images = images_of(product.get("image"), page_url)
    if not images:
        images = images_of(meta_content(page, "og:image"), page_url)
    for variant in as_list(variants):
        if isinstance(variant, dict) and len(images) < IMAGE_LIMIT:
            images += [i for i in images_of(variant.get("image"), page_url) if i not in images]
    description = text(product.get("description")) or meta_content(page, "og:description")
    audience = product.get("audience") if isinstance(product.get("audience"), dict) else {}
    # The sitemap page is the product's identity and link: some shops point og:url / JSON-LD url
    # at a shared or generic page, which collapsed many products into one.
    canonical = page_url

    return {
        "url": canonical,
        "sku": text(product.get("sku") or product.get("productGroupID") or product.get("mpn")),
        "title": title,
        "brand": text(product.get("brand")) or meta_content(page, "product:brand"),
        "description": description[:DESCRIPTION_LIMIT] if description else None,
        "color": text(product.get("color")) or meta_content(page, "product:color"),
        "material": text(product.get("material")),
        "categoryPath": category_path or text(product.get("category")),
        "gender": guess_gender(text(audience.get("suggestedGender")), category_path, readable(canonical), title),
        "sizes": sizes,
        "inStockSizes": in_stock_sizes,
        "images": list(dict.fromkeys(images))[:IMAGE_LIMIT],
        "price": price,
        "originalPrice": float(original) if original and re.fullmatch(r"[\d.]+", original) else None,
        "currency": currency,
        "available": available,
    }


# MARK: - Shopify

def shopify_products(store, log):
    """All products of a Shopify store, or None if the store isn't Shopify."""
    base = store["base"].rstrip("/")
    products, page = [], 1
    while page <= 40:
        try:
            data = json.loads(fetch(f"{base}/products.json?limit=250&page={page}", accept="application/json"))
        except (urllib.error.URLError, TimeoutError, ValueError, json.JSONDecodeError):
            return None if page == 1 else products
        batch = data.get("products") or []
        if not batch:
            break
        for item in batch:
            options = [o.get("name", "").lower() for o in item.get("options", [])]
            size_index = next((i for i, n in enumerate(options) if n in ("size", "מידה")), None)
            color_index = next((i for i, n in enumerate(options) if n in ("color", "colour", "צבע")), None)
            variants = item.get("variants", [])
            def option(variant, index):
                return variant.get(f"option{index + 1}") if index is not None else None
            sizes = list(dict.fromkeys(filter(None, (option(v, size_index) for v in variants))))
            in_stock = list(dict.fromkeys(filter(None, (option(v, size_index) for v in variants if v.get("available")))))
            prices = [float(v["price"]) for v in variants if v.get("price")]
            compare = [float(v["compare_at_price"]) for v in variants if v.get("compare_at_price")]
            description = text(item.get("body_html"))
            path = " > ".join(filter(None, [item.get("product_type"), ", ".join(item.get("tags", [])[:8]) if isinstance(item.get("tags"), list) else item.get("tags")]))
            products.append({
                "url": f"{base}/products/{item.get('handle')}",
                "sku": str(item.get("id")),
                "title": text(item.get("title")),
                "brand": text(item.get("vendor")),
                "description": description[:DESCRIPTION_LIMIT] if description else None,
                "color": next(filter(None, (option(v, color_index) for v in variants)), None),
                "material": None,
                "categoryPath": path or None,
                "gender": guess_gender(path, item.get("title")),
                "sizes": sizes,
                "inStockSizes": in_stock,
                "images": [i.get("src") for i in item.get("images", [])[:IMAGE_LIMIT] if i.get("src")],
                "price": min(prices) if prices else None,
                "originalPrice": max(compare) if compare else None,
                "currency": None,
                "available": any(v.get("available") for v in variants),
            })
        page += 1
        time.sleep(store.get("delaySeconds", 1.0))
    log.append(f"shopify: {len(products)} products")
    return products


# MARK: - Store run

def item_id(store_id, url):
    return f"{store_id}:{hashlib.sha1(url.encode('utf-8')).hexdigest()[:16]}"


def crawl_store(store, previous_items, country):
    log, started = [], time.time()
    base = store["base"].rstrip("/")
    stamp = now_iso()

    shopify = None if store.get("productUrlPattern") else shopify_products(store, log)
    if shopify is not None:
        items = []
        for product in shopify:
            product.update(id=item_id(store["id"], product["url"]), store=store["id"], country=country, fetchedAt=stamp,
                           currency=product["currency"] or store.get("currency"))
            items.append(product)
        return items, {"status": "ok", "source": "shopify", "items": len(items), "log": log[-20:], "seconds": round(time.time() - started)}

    robots = urllib.robotparser.RobotFileParser(f"{base}/robots.txt")
    try:
        robots.parse(fetch(f"{base}/robots.txt", accept="text/plain").splitlines())
    except (urllib.error.URLError, TimeoutError, ValueError) as error:
        return list(previous_items.values()), {"status": "unreachable", "error": str(error), "items": len(previous_items)}
    delay = max(store.get("delaySeconds", 1.0), float(robots.crawl_delay(USER_AGENT) or 0))

    urls = [u for u in discover_product_urls(store, robots, log) if robots.can_fetch(USER_AGENT, u)]
    if not urls:
        return list(previous_items.values()), {"status": "no-urls", "items": len(previous_items), "log": log[-20:]}

    known = {item["sourcePage"]: item for item in previous_items.values() if item.get("sourcePage")}
    live = set(urls)
    fresh = [u for u in urls if u not in known]
    # Sitemaps list products in catalog order (one department at a time); a shuffled pick
    # gives the first nights a catalog that covers every department.
    random.Random(datetime.now(timezone.utc).strftime("%Y-%m-%d") + store["id"]).shuffle(fresh)
    stale = sorted((u for u in urls if u in known), key=lambda u: known[u].get("fetchedAt", ""))
    budget = store.get("maxPagesPerRun", 1000)
    to_fetch = (fresh + stale)[:budget]

    results = {u: item for u, item in known.items() if u in live}
    failures = not_products = 0
    for page_url in to_fetch:
        try:
            product = parse_product_page(fetch(page_url), page_url)
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            failures += 1
            if failures <= 5:
                log.append(f"page failed {page_url}: {error}")
            if failures >= 25 and failures > len(to_fetch) // 2:
                log.append("too many failures, stopping this store")
                break
            continue
        finally:
            time.sleep(delay)
        if product is None:
            not_products += 1
            results.pop(page_url, None)
            continue
        product.update(id=item_id(store["id"], product["url"]), store=store["id"], country=country,
                       sourcePage=page_url, fetchedAt=now_iso(), currency=product["currency"] or store.get("currency"))
        results[page_url] = product

    items = list({item["id"]: item for item in results.values()}.values())
    report = {
        "status": "ok", "source": "sitemap", "items": len(items), "productUrls": len(urls),
        "fetched": len(to_fetch), "failed": failures, "notProducts": not_products,
        "seconds": round(time.time() - started), "log": log[-20:],
    }
    return items, report


# MARK: - Probe

GRAPHQL_PROBE = '{products(search:"shirt",pageSize:2){total_count items{__typename sku name url_key url_suffix}}}'


def probe_store(store):
    """What a store exposes, for tuning stores.json from a GitHub Actions log (`--probe`)."""
    base = store["base"].rstrip("/")
    out = {"id": store["id"]}
    robots = urllib.robotparser.RobotFileParser(f"{base}/robots.txt")
    try:
        robots.parse(fetch(f"{base}/robots.txt", accept="text/plain").splitlines())
        out["sitemaps"] = robots.site_maps()
    except Exception as error:  # noqa: BLE001 - diagnostics only
        out["robots"] = str(error)
        return out
    children, sample = [], []
    for sitemap in (robots.site_maps() or [f"{base}/sitemap.xml"])[:3]:
        try:
            kids, urls = sitemap_locations(fetch(sitemap, accept="application/xml,text/xml,*/*"))
        except Exception as error:  # noqa: BLE001
            children.append(f"{sitemap}: {error}")
            continue
        children += kids
        sample += urls[:20]
    out["children"] = [readable(c) for c in children[:40]]
    for child in [c for c in children if looks_like_product_sitemap(c)][:2] or children[:2]:
        try:
            _, urls = sitemap_locations(fetch(child, accept="application/xml,text/xml,*/*"))
            out.setdefault("childCounts", {})[readable(child)] = len(urls)
            sample += urls[:: max(1, len(urls) // 15)][:15]
        except Exception as error:  # noqa: BLE001
            out.setdefault("childCounts", {})[readable(child)] = str(error)
    out["sampleUrls"] = [readable(u) for u in sample[:30]]
    pages = []
    for url in [u for u in sample if urllib.parse.urlsplit(u).path.count("/") >= 1][-6:]:
        info = {"url": readable(url)}
        try:
            page = fetch(url)
            nodes = list(json_ld_blocks(page))
            info.update(
                length=len(page),
                ldTypes=sorted({str(t) for n in nodes for t in types_of(n)}),
                ogType=meta_content(page, "og:type"),
                hasNextData="__NEXT_DATA__" in page,
                hasInitialState="__INITIAL_STATE__" in page or "__APOLLO_STATE__" in page,
                mentionsMagento="magento" in page.lower() or "mage/" in page.lower(),
                parsed=bool(parse_product_page(page, url)),
            )
            if info["parsed"] and "product" not in out:
                out["product"] = parse_product_page(page, url)
                product_node = next((n for n in nodes if types_of(n) & {"Product", "ProductGroup"}), {})
                out["productKeys"] = sorted(product_node.keys())
                out["breadcrumbHtml"] = bool(re.search(r"breadcrumb", page, re.I))
        except Exception as error:  # noqa: BLE001
            info["error"] = str(error)
        pages.append(info)
        time.sleep(store.get("delaySeconds", 1.0))
    out["pages"] = pages
    try:
        query = urllib.parse.quote(GRAPHQL_PROBE)
        out["graphql"] = fetch(f"{base}/graphql?query={query}", accept="application/json")[:600]
    except Exception as error:  # noqa: BLE001
        out["graphql"] = str(error)
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--country", default="IL")
    parser.add_argument("--out", required=True)
    parser.add_argument("--previous")
    parser.add_argument("--stores", default=os.path.join(os.path.dirname(__file__), "stores.json"))
    parser.add_argument("--only", help="comma-separated store ids")
    parser.add_argument("--probe", action="store_true", help="print what each store exposes, build nothing")
    args = parser.parse_args()

    stores = json.load(open(args.stores, encoding="utf-8"))[args.country]
    if args.only:
        wanted = set(args.only.split(","))
        stores = [s for s in stores if s["id"] in wanted]

    if args.probe:
        for store in stores:
            print(json.dumps(probe_store(store), ensure_ascii=False, indent=2))
        return

    previous = {}
    if args.previous and os.path.exists(args.previous):
        try:
            for item in json.load(open(args.previous, encoding="utf-8")).get("items", []):
                previous.setdefault(item["store"], {})[item["id"]] = item
        except (json.JSONDecodeError, KeyError):
            print("previous catalog unreadable, starting fresh", file=sys.stderr)

    all_items, reports = [], {}
    for store in stores:
        items, report = crawl_store(store, previous.get(store["id"], {}), args.country)
        reports[store["id"]] = {"name": store["name"], **report}
        all_items.extend(items)
        print(f"{store['id']}: {report.get('status')} · {report.get('items')} items", file=sys.stderr)

    os.makedirs(args.out, exist_ok=True)
    generated = now_iso()
    catalog = {
        "version": 1,
        "country": args.country,
        "generatedAt": generated,
        "stores": [{"id": s["id"], "name": s["name"], "base": s["base"], "items": reports[s["id"]]["items"]} for s in stores],
        "items": all_items,
    }
    with open(os.path.join(args.out, "catalog.json"), "w", encoding="utf-8") as handle:
        json.dump(catalog, handle, ensure_ascii=False, separators=(",", ":"))
    with open(os.path.join(args.out, "report.json"), "w", encoding="utf-8") as handle:
        json.dump({"generatedAt": generated, "stores": reports}, handle, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
