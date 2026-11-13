#!/usr/bin/env python3
"""Builds the shop catalog the app ranks on the device (plan: project plans/shopping-israel.md).

For each store in stores.json: robots.txt -> sitemaps -> product pages, reading the JSON-LD
Product / ProductGroup and Open Graph data every shop publishes for search engines. Shopify stores
are read from /products.json instead. Only raw fields are stored; the app maps them to its taxonomy
through ProductPageMetadataService.makeProduct / ProductFieldMapper, so mapping lives in one place.

Runs are incremental: each run reserves a refresh budget for existing items before discovering
new products. Products whose URL left the sitemap are dropped.

Usage: python3 scripts/catalog/build_catalog.py --country IL --out out/il [--previous prev.json]
No third-party packages."""
import argparse
import gzip
import hashlib
import html
import json
import math
import os
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
PRICE_EVIDENCE_VERSION = 3
PRODUCT_SITEMAP_HINT = re.compile(r"product|prod|item|catalog", re.I)


def looks_like_product_sitemap(url):
    # "sitemap" itself contains "item", so match on the file name without it.
    name = urllib.parse.urlparse(url).path.rsplit("/", 1)[-1].lower().replace("sitemap", "")
    return bool(PRODUCT_SITEMAP_HINT.search(name))


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def fetch(url, accept="text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"):
    # Castro's sitemaps contain literal Hebrew paths. urllib otherwise fails before
    # making a request; keep existing escapes and URL separators intact.
    request_url = urllib.parse.quote(url, safe=":/?#[]@!$&'()*+,;=%")
    request = urllib.request.Request(request_url, headers={
        "User-Agent": USER_AGENT,
        "Accept": accept,
        "Accept-Language": "he-IL,he;q=0.9,en;q=0.6",
        "Accept-Encoding": "gzip",
    })
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
        pages = [u for u in pages if pattern.search(u)]
    elif urllib.parse.urlparse(base).hostname in ("www.terminalx.com", "terminalx.com"):
        # Their sitemap includes 90k+ navigation/category routes. Product routes
        # are a letter followed by a 5-digit group or 9-digit color SKU.
        pages = [u for u in pages if re.fullmatch(r"/[a-z]\d{5}(?:\d{4})?/?", urllib.parse.urlparse(u).path, re.I)]
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
    return value if value and value.lower() not in ("null", "undefined") else None


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


def distinct_images(urls):
    # Magento repeats one photo through thumbnail/gallery cache URLs. Keep one
    # angle per source asset, while retaining every distinct same-color photo.
    images, seen = [], set()
    for url in urls:
        parsed = urllib.parse.urlparse(url)
        path = re.sub(r"/catalog/product/cache/[^/]+/", "/catalog/product/", parsed.path)
        key = (parsed.netloc.lower(), path)
        if key not in seen:
            seen.add(key)
            images.append(url)
    return images


def as_list(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def positive_price(value):
    try:
        value = float(str(value).replace(",", ""))
        return value if math.isfinite(value) and value > 0 else None
    except (TypeError, ValueError):
        return None


def availability_of(value):
    label = str(value or "").rsplit("/", 1)[-1].lower()
    if label in ("instock", "limitedavailability", "onlineonly", "instoreonly", "in stock"):
        return True
    if label in ("outofstock", "soldout", "discontinued", "preorder", "presale", "backorder", "out of stock"):
        return False
    return None


def offer_details(offers):
    """A current/regular-price pair from the same Offer, plus tri-state stock.

    AggregateOffer.highPrice is another variant's price, never a crossed-out price.
    Prefer an in-stock offer so a sold-out variant cannot supply the advertised low price.
    """
    facts = []
    for offer in as_list(offers):
        if not isinstance(offer, dict):
            continue
        if offer.get("offers"):
            facts.append(offer_details(offer["offers"]))
            continue
        price = positive_price(offer.get("price")) or positive_price(offer.get("lowPrice"))
        currency = offer.get("priceCurrency")
        regular_prices = []
        for spec in as_list(offer.get("priceSpecification")):
            if not isinstance(spec, dict):
                continue
            amount = positive_price(spec.get("price"))
            if amount is None:
                continue
            kind = str(spec.get("priceType") or "").rsplit("/", 1)[-1].lower()
            if kind in ("strikethroughprice", "listprice", "regularprice"):
                regular_prices.append((amount, spec.get("priceCurrency")))
            elif not spec.get("eligibleCustomerType") and not spec.get("validForMemberTier"):
                price = price or amount
                currency = currency or spec.get("priceCurrency")
        original = min((p for p, c in regular_prices if price is not None and p > price and (not c or not currency or c == currency)), default=None)
        facts.append((price, currency, availability_of(offer.get("availability")), original))
    if not facts:
        return None, None, None, None
    availability = True if any(f[2] is True for f in facts) else (None if any(f[2] is None for f in facts) else False)
    candidates = [f for f in facts if f[2] is availability and f[0] is not None]
    chosen = min(candidates, key=lambda f: f[0]) if candidates else next(f for f in facts if f[2] is availability)
    return chosen[0], chosen[1], availability, chosen[3]


def offer_facts(offers):
    return offer_details(offers)[:3]


def variant_sizes(variants):
    sizes, in_stock, known = [], [], []
    for variant in as_list(variants):
        if not isinstance(variant, dict):
            continue
        size = text(variant.get("size"))
        if not size:
            continue
        sizes.append(size)
        _, _, available = offer_facts(variant.get("offers"))
        known.append(available is not None)
        if available:
            in_stock.append(size)
    return list(dict.fromkeys(sizes)), list(dict.fromkeys(in_stock)), bool(known) and all(known)


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
    ("kids", r"\b(kids?|children|boys?|girls?|bab(y|ies)|junior|toddler|youth)\b|ילדים|ילדות|תינוק|בנים|בנות|נוער"),
    ("women", r"\b(women|womens|woman|female|ladies)\b|נשים|אישה|לנשים"),
    ("men", r"\b(men|mens|man|male)\b|גברים|לגבר|לגברים"),
]


def guess_gender(*hints):
    # Explicit audience is passed first. Do not let broad navigation labels override it.
    for hint in hints:
        joined = urllib.parse.unquote(str(hint or "")).lower()
        if re.search(r"\bunisex\b|יוניסקס", joined):
            return "unisex"
        matches = [gender for gender, pattern in GENDER_WORDS if re.search(pattern, joined)]
        if len(matches) == 1:
            return matches[0]
    return None


def leaf_product_variants(product):
    """Preserve a color group's fields when its children hold the individual sizes."""
    variants = []
    for variant in as_list(product.get("hasVariant")):
        if not isinstance(variant, dict):
            continue
        if variant.get("hasVariant"):
            # A group's in-stock aggregate does not establish stock for every size below it.
            own_fields = {"hasVariant", "offers", "size", "sku", "mpn", "gtin", "gtin8", "gtin12", "gtin13", "gtin14"}
            inherited = {key: value for key, value in variant.items() if key not in own_fields}
            variants.extend({**inherited, **child} for child in leaf_product_variants(variant))
        else:
            variants.append(variant)
    return variants


def select_product_variant(variants, product, page_url):
    """Select one color before combining any size/stock data."""
    if not variants:
        return None, [], True
    def color_key(value):
        return re.sub(r"\s+", " ", text(value) or "").strip().lower()
    def variant_url(variant):
        raw = text(variant.get("url"))
        return urllib.parse.urldefrag(urllib.parse.urljoin(page_url, raw))[0] if raw else None
    page = urllib.parse.urldefrag(page_url)[0]
    matched = [v for v in variants if variant_url(v) == page]
    parent_color = color_key(product.get("color"))
    same_as_parent = [v for v in variants if parent_color and color_key(v.get("color")) == parent_color]
    candidates = matched or same_as_parent or variants
    details = [(v, offer_details(v.get("offers"))) for v in candidates]
    live = [entry for entry in details if entry[1][2] is True]
    unknown = [entry for entry in details if entry[1][2] is None]
    pool = live or unknown or details
    selected = min(pool, key=lambda entry: entry[1][0] if entry[1][0] is not None else float("inf"))[0]
    selected_color = color_key(selected.get("color"))
    color_scope_known = True
    if selected_color:
        same_color = [v for v in variants if color_key(v.get("color")) == selected_color]
    elif parent_color and all(not color_key(v.get("color")) for v in variants):
        # The parent names one color and its size variants do not override it.
        same_color = variants if not isinstance(product.get("color"), list) else [selected]
        color_scope_known = not isinstance(product.get("color"), list)
    else:
        # Missing child colors cannot establish that another child's sizes belong here.
        same_color = [selected]
        color_scope_known = len(variants) == 1
    return selected, same_color, color_scope_known


def has_ambiguous_offers(offers):
    nodes = [offer for offer in as_list(offers) if isinstance(offer, dict)]
    if len(nodes) > 1:
        return True
    return any("AggregateOffer" in types_of(offer) or offer.get("offers") for offer in nodes)


def retailer_product_details(page, page_url, price, currency):
    """Read purchase facts from the exact product/selected color, never related items.

    These are public server-rendered product fields, not coupon/member/basket prices.
    Keep the JSON-LD current price authoritative and require an exact same-currency match.
    """
    parsed = urllib.parse.urlparse(page_url)
    host = (parsed.hostname or "").lower()
    decoder = json.JSONDecoder()
    details = {}

    def gallery_images(entries):
        entries = [entry for entry in as_list(entries) if isinstance(entry, dict)]
        entries.sort(key=lambda entry: positive_price(entry.get("position")) or 0)
        return [image for entry in entries if not entry.get("disabled") and entry.get("type", "image") == "image"
                for image in images_of(entry.get("full") or entry.get("img") or entry.get("url"), page_url)]

    def regular_price(bounds):
        pairs = []
        for key in ("minimum_price", "maximum_price"):
            bound = bounds.get(key) or {}
            final, regular = bound.get("final_price") or {}, bound.get("regular_price") or {}
            if final.get("currency") != currency or regular.get("currency") != currency:
                return None
            pairs.append((positive_price(final.get("value")), positive_price(regular.get("value"))))
        if price is not None and len(set(pairs)) == 1 and pairs[0][0] == price and pairs[0][1] is not None and pairs[0][1] > price:
            return pairs[0][1]
        return None

    if host in ("www.terminalx.com", "terminalx.com"):
        marker = re.search(r'window\.__INITIAL_STATE__\s*=\s*', page)
        if not marker:
            return details
        # The SSR serializer splits script tags with literal concatenation.
        # Normalize those two known sequences; never evaluate JavaScript.
        raw = page[marker.end():].replace('<"+"script', '<script').replace('<"+"/script', '</script')
        try:
            state, _ = decoder.raw_decode(raw)
            product = state["productPageStoreData"]["data"]["mainProduct"]
        except (ValueError, TypeError, KeyError):
            return details
        if not isinstance(product, dict):
            return details
        sku = str(product.get("sku") or "").casefold()
        route = urllib.parse.unquote(parsed.path).strip("/").split("/")[0].casefold()
        if not sku or sku != route:
            return details
        details["images"] = gallery_images(product.get("media_gallery"))
        category_names = [text(category.get("name")) for category in as_list(product.get("categories")) if isinstance(category, dict)]
        category_names = list(dict.fromkeys(name for name in category_names if name))
        details["categoryPath"] = " > ".join(category_names) or None
        details["gender"] = guess_gender(" ".join(category_names))
        material = text(product.get("fabric"))
        details["material"] = material if material and material.lower() not in ("null", "none", "undefined") else None

        # Configurations include other colors. Parent SKU ties each child back to
        # the page's color before using its gallery, size scale or stock.
        scoped_variants = []
        for variant in as_list(product.get("variants")):
            child = variant.get("product") if isinstance(variant, dict) else None
            if not isinstance(child, dict):
                continue
            parent = (child.get("parent_product") or {}).get("product") or {}
            if str(parent.get("sku") or "").casefold() == sku:
                scoped_variants.append((variant, child))
                details["images"] += gallery_images(child.get("media_gallery"))
        sizes, in_stock, known = [], [], []
        for variant, child in scoped_variants:
            size = text(child.get("size_scale")) or next((text(a.get("label")) for a in as_list(variant.get("attributes"))
                                                         if isinstance(a, dict) and a.get("code") == "size"), None)
            if not size:
                continue
            sizes.append(size)
            available = availability_of(str(child.get("stock_status2") or "").replace("_", ""))
            known.append(available is not None)
            if available is True:
                in_stock.append(size)
        if sizes:
            details.update(sizes=list(dict.fromkeys(sizes)), inStockSizes=list(dict.fromkeys(in_stock)),
                           sizeAvailabilityKnown=bool(known) and all(known))
        # Both bounds must describe the same offer; a cheapest size cannot borrow
        # the regular price from a more expensive size or another color.
        details["originalPrice"] = regular_price(product.get("price_range") or {})
        if details["originalPrice"] is None and scoped_variants:
            live = [child for _, child in scoped_variants if availability_of(str(child.get("stock_status2") or "").replace("_", "")) is True]
            regulars = [regular_price(child.get("price_range") or {}) for child in live]
            if regulars and None not in regulars and len(set(regulars)) == 1:
                details["originalPrice"] = regulars[0]

    if host in ("www.castro.com", "castro.com"):
        # Product identity comes from the current product's hidden input and URL key.
        from html.parser import HTMLParser
        class ProductInputs(HTMLParser):
            def __init__(self):
                super().__init__()
                self.ids = set()
                self.images = []
            def handle_starttag(self, tag, attrs):
                attributes = dict(attrs)
                if tag == "input" and attributes.get("name") == "product":
                    route = urllib.parse.unquote(parsed.path).strip("/").split("/")[-1]
                    if attributes.get("url_key") == route and attributes.get("value"):
                        self.ids.add(attributes["value"])
                if attributes.get("data-gallery-role") == "gallery-placeholder":
                    try:
                        config = json.loads(attributes.get("data-mage-init") or "{}")
                    except ValueError:
                        return
                    for key in ("Idus_Product/js/gallery", "mage/gallery/gallery"):
                        self.images += gallery_images((config.get(key) or {}).get("data"))
        inputs = ProductInputs()
        inputs.feed(page)
        if len(inputs.ids) != 1:
            return details
        details["images"] = inputs.images
        for marker in re.finditer(r'"jsonConfig"\s*:\s*', page):
            try:
                config, _ = decoder.raw_decode(page[marker.end():])
            except ValueError:
                continue
            if not isinstance(config, dict) or str(config.get("productId")) not in inputs.ids:
                continue
            color = next((a for a in (config.get("attributes") or {}).values() if isinstance(a, dict) and a.get("code") == "color"), None)
            if not color or not color.get("default"):
                continue
            option = next((o for o in color.get("options", []) if str(o.get("id")) == str(color["default"])), None)
            stock = (option or {}).get("products") or {}
            if not isinstance(stock, dict):
                continue
            ids = stock.get("stock") or []
            index = config.get("index") or {}
            all_ids = [str(item_id) for item_id, attributes in index.items()
                       if isinstance(attributes, dict) and str(attributes.get(str(color["id"]))) == str(color["default"])]
            details["color"] = text((option or {}).get("label"))
            for item_id in (all_ids or ids):
                details["images"] += gallery_images((config.get("images") or {}).get(str(item_id)))
            size = next((a for a in (config.get("attributes") or {}).values() if isinstance(a, dict) and a.get("code") == "size"), None)
            if size and all_ids:
                size_labels = {str(o.get("id")): text(o.get("label")) for o in size.get("options", []) if isinstance(o, dict)}
                sizes, in_stock = [], []
                live_ids = {str(item_id) for item_id in ids}
                for item_id in all_ids:
                    label = size_labels.get(str(index[item_id].get(str(size["id"]))))
                    if label:
                        sizes.append(label)
                        if item_id in live_ids:
                            in_stock.append(label)
                if sizes:
                    details.update(sizes=list(dict.fromkeys(sizes)), inStockSizes=list(dict.fromkeys(in_stock)),
                                   sizeAvailabilityKnown="stock" in stock)
            prices = config.get("optionPrices") or {}
            pairs = []
            for item_id in ids:
                offer = prices.get(str(item_id)) or {}
                pairs.append((positive_price((offer.get("finalPrice") or {}).get("amount")),
                              positive_price((offer.get("oldPrice") or {}).get("amount"))))
            if currency == "ILS" and pairs and len(set(pairs)) == 1 and pairs[0][0] == price and pairs[0][1] is not None and pairs[0][1] > price:
                details["originalPrice"] = pairs[0][1]
            break
    return details


def parse_product_page(page, page_url):
    """Raw product fields from one page, or None if the page isn't a product."""
    nodes = list(json_ld_blocks(page))
    product = next((n for n in nodes if types_of(n) & {"Product", "ProductGroup"}), None)
    category_path = breadcrumb_path(nodes)
    og_type = (meta_content(page, "og:type") or "").lower()
    if product is None and "product" not in og_type:
        return None
    product = product or {}

    variants = leaf_product_variants(product)
    selected, color_variants, color_scope_known = select_product_variant(variants, product, page_url)
    concrete = selected or product
    sizes, in_stock_sizes, size_availability_known = variant_sizes(color_variants)
    if not color_scope_known:
        in_stock_sizes, size_availability_known = [], False
    price, currency, available, original = offer_details(concrete.get("offers"))
    if color_variants:
        _, _, color_available = offer_facts([o for v in color_variants for o in as_list(v.get("offers"))])
        available = color_available
    meta_price = positive_price(meta_content(page, "product:price:amount") or meta_content(page, "og:price:amount"))
    meta_currency = meta_content(page, "product:price:currency") or meta_content(page, "og:price:currency")
    # Page metadata can refer to the initially displayed color, not an arbitrary chosen variant.
    unambiguous_page = not variants and not has_ambiguous_offers(product.get("offers"))
    if price is None and not variants:
        price = meta_price
    if not variants:
        currency = currency or meta_currency
    if available is None and not variants:
        availability = meta_content(page, "product:availability") or meta_content(page, "og:availability")
        available = availability_of(availability)
    if sizes and available is None and size_availability_known:
        available = bool(in_stock_sizes)
    if not sizes and concrete.get("size"):
        sizes = [s.strip() for s in (text(concrete.get("size")) or "").split(",") if s.strip()]

    explicit_original = positive_price(meta_content(page, "product:original_price:amount"))
    same_currency = not currency or not meta_currency or currency == meta_currency
    if original is None and unambiguous_page and same_currency and meta_price == price and explicit_original is not None and price is not None and explicit_original > price:
        original = explicit_original
    try:
        retail = retailer_product_details(page, page_url, price, currency) if not variants else {}
    except (ValueError, TypeError, KeyError, AttributeError):
        # A retailer changing its optional configuration must not discard an
        # otherwise usable JSON-LD product or invent purchase facts.
        retail = {}
    if original is None:
        original = retail.get("originalPrice")
    if retail.get("sizes"):
        sizes = retail["sizes"]
        in_stock_sizes = retail.get("inStockSizes", [])
        size_availability_known = retail.get("sizeAvailabilityKnown", False)
        if size_availability_known:
            available = bool(in_stock_sizes)
    title = text(concrete.get("name")) or text(product.get("name")) or meta_content(page, "og:title")
    if not title:
        return None
    images = images_of(concrete.get("image"), page_url)
    for variant in color_variants:
        images += [i for i in images_of(variant.get("image"), page_url) if i not in images]
    images = retail.get("images", []) + images
    parent_color = text(product.get("color"))
    concrete_color = text(concrete.get("color")) or parent_color
    if not images and color_scope_known and parent_color and concrete_color and parent_color.lower() == concrete_color.lower():
        images = images_of(product.get("image"), page_url)
    if not images and not variants:
        images = images_of(meta_content(page, "og:image"), page_url)
    description = text(concrete.get("description")) or text(product.get("description")) or meta_content(page, "og:description")
    audience = product.get("audience") if isinstance(product.get("audience"), dict) else {}
    canonical = text(concrete.get("url")) or text(product.get("url")) or meta_content(page, "og:url") or page_url
    canonical = urllib.parse.urljoin(page_url, canonical)

    return {
        "url": canonical,
        "sku": text(concrete.get("sku") or product.get("sku") or product.get("productGroupID") or product.get("mpn")),
        "title": title,
        "brand": text(concrete.get("brand")) or text(product.get("brand")) or meta_content(page, "product:brand"),
        "description": description[:DESCRIPTION_LIMIT] if description else None,
        "color": text(concrete.get("color")) or (text(product.get("color")) if not isinstance(product.get("color"), list) else None) or retail.get("color") or (meta_content(page, "product:color") if not variants else None),
        "material": retail.get("material") or text(concrete.get("material")) or text(product.get("material")),
        "categoryPath": category_path or retail.get("categoryPath") or text(product.get("category")),
        "gender": guess_gender(text(audience.get("suggestedGender")), text(product.get("gender")), title, retail.get("gender"), category_path, canonical),
        "sizes": sizes,
        "inStockSizes": in_stock_sizes,
        "sizeAvailabilityKnown": size_availability_known,
        "images": distinct_images(images),
        "price": price,
        "originalPrice": original,
        "originalPriceVerified": original is not None,
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
        except (urllib.error.URLError, TimeoutError, ValueError, json.JSONDecodeError) as error:
            log.append(f"shopify page {page} failed: {error}; using incremental sitemap fallback")
            return None
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
            live = [v for v in variants if v.get("available") is True]
            priced = [v for v in (live or variants) if positive_price(v.get("price")) is not None]
            selected = min(priced, key=lambda v: positive_price(v.get("price"))) if priced else next(iter(live or variants), {})
            color = option(selected, color_index)
            # Keep the selected color's stock and imagery with its price.
            color_variants = [v for v in variants if color_index is None or option(v, color_index) == color]
            sizes = list(dict.fromkeys(filter(None, (option(v, size_index) for v in color_variants))))
            in_stock = list(dict.fromkeys(filter(None, (option(v, size_index) for v in color_variants if v.get("available") is True))))
            price = positive_price(selected.get("price"))
            original = positive_price(selected.get("compare_at_price"))
            if original is not None and (price is None or original <= price):
                original = None
            images = item.get("images", [])
            if selected.get("image_id") is not None:
                images = sorted(images, key=lambda image: image.get("id") != selected["image_id"])
            description = text(item.get("body_html"))
            path = " > ".join(filter(None, [item.get("product_type"), ", ".join(item.get("tags", [])[:8]) if isinstance(item.get("tags"), list) else item.get("tags")]))
            products.append({
                "url": f"{base}/products/{item.get('handle')}",
                "sku": str(item.get("id")),
                "title": text(item.get("title")),
                "brand": text(item.get("vendor")),
                "description": description[:DESCRIPTION_LIMIT] if description else None,
                "color": color,
                "material": None,
                "categoryPath": path or None,
                "gender": guess_gender(item.get("title"), path),
                "sizes": sizes,
                "inStockSizes": in_stock,
                "sizeAvailabilityKnown": bool(size_index is not None and color_variants) and all(isinstance(v.get("available"), bool) for v in color_variants),
                "images": distinct_images([i.get("src") for i in images if i.get("src")]),
                "price": price,
                "originalPrice": original,
                "originalPriceVerified": original is not None,
                "currency": None,
                "available": True if any(v.get("available") is True for v in color_variants) else (False if color_variants and all(v.get("available") is False for v in color_variants) else None),
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
    stale = sorted((u for u in urls if u in known),
                   key=lambda u: (known[u].get("priceEvidenceVersion", 0) >= PRICE_EVIDENCE_VERSION, known[u].get("fetchedAt", "")))
    budget = max(0, store.get("maxPagesPerRun", 1000))
    # Reserve most of each run for refreshing prices. New sitemap URLs previously
    # starved existing items, leaving old prices and unverified discounts indefinitely.
    refresh_count = min(len(stale), max(1, budget * 3 // 5)) if budget else 0
    refresh = stale[:refresh_count]
    to_fetch = (refresh + fresh[:max(0, budget - len(refresh))])[:budget]
    if len(to_fetch) < budget:
        to_fetch += stale[refresh_count:refresh_count + budget - len(to_fetch)]

    results = {u: item for u, item in known.items() if u in live}
    failures = not_products = attempted = refreshed = consecutive_failures = 0
    for page_url in to_fetch:
        attempted += 1
        try:
            product = parse_product_page(fetch(page_url), page_url)
            consecutive_failures = 0
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            failures += 1
            consecutive_failures += 1
            if isinstance(error, urllib.error.HTTPError) and error.code in (404, 410):
                results.pop(page_url, None)
            if failures <= 5:
                log.append(f"page failed {page_url}: {error}")
            if consecutive_failures >= 25 or (failures >= 25 and failures > len(to_fetch) // 2):
                log.append("too many failures, stopping this store; unrefreshed products kept with their original fetch dates")
                break
            continue
        finally:
            time.sleep(delay)
        if product is None:
            not_products += 1
            results.pop(page_url, None)
            continue
        product.update(id=item_id(store["id"], product["url"]), store=store["id"], country=country,
                       sourcePage=page_url, fetchedAt=now_iso(), priceEvidenceVersion=PRICE_EVIDENCE_VERSION, currency=product["currency"] or store.get("currency"))
        results[page_url] = product
        refreshed += 1

    items = list({item["id"]: item for item in results.values()}.values())
    report = {
        "status": "ok", "source": "sitemap", "items": len(items), "productUrls": len(urls),
        "scheduled": len(to_fetch), "attempted": attempted, "fetched": attempted - failures,
        "refreshed": refreshed, "failed": failures, "notProducts": not_products,
        "verifiedDiscounts": sum(bool(item.get("originalPriceVerified") and item.get("originalPrice")
                                      and item.get("price") and item["originalPrice"] > item["price"]) for item in items),
        "missingImages": sum(not item.get("images") for item in items),
        "seconds": round(time.time() - started), "log": log[-20:],
    }
    return items, report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--country", default="IL")
    parser.add_argument("--out", required=True)
    parser.add_argument("--previous")
    parser.add_argument("--stores", default=os.path.join(os.path.dirname(__file__), "stores.json"))
    parser.add_argument("--only", help="comma-separated store ids")
    args = parser.parse_args()

    stores = json.load(open(args.stores, encoding="utf-8"))[args.country]
    if args.only:
        wanted = set(args.only.split(","))
        stores = [s for s in stores if s["id"] in wanted]

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
