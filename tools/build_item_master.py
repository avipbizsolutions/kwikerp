"""Build the KwikERP import-ready item master from the Troika pricing sheet.

Input : db/seed/source/troika_product_pricing_2026-10.csv  (raw export of the
        "Troika Product Pricing" Google Sheet, 107 items)
Output: db/seed/troika_items.csv   one row per item
        db/seed/troika_prices.csv  one row per item x unit x price level

Run:  python3 tools/build_item_master.py

Everything this script assumes (pack sizes, GST, HSN, shelf life) is marked in
the output so it can be checked and corrected in the sheet, not in code.
"""
import csv
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "db/seed/source/troika_product_pricing_2026-10.csv"
OUT_ITEMS = ROOT / "db/seed/troika_items.csv"
OUT_PRICES = ROOT / "db/seed/troika_prices.csv"
PRICE_DATE = "2026-10-11"  # rate chart in force when the sheet was exported

# Sheet column -> KwikERP price level code
LEVELS = {
    "Consumer": "CONSUMER",
    "Retailer": "RETAILER",
    "Distributor": "DISTRIBUTOR",
    "Franchisee": "FRANCHISE",
    "SpecialRate2": "SPECIAL",
}

# Sheet category -> (KwikERP category code, item kind, show on outlet POS)
CATEGORY = {
    "Milk": ("MILK", "own", True),
    "Dahi Small": ("DAHI", "own", True),
    "Dahi Bulk": ("DAHI_BULK", "own", True),
    "Lassi": ("LASSI", "own", True),
    "Flavoured Milk": ("FLAV_MILK", "own", True),
    "Paneer": ("PANEER", "own", True),
    "Ghee": ("GHEE", "own", True),
    "Khoa": ("KHOA", "own", True),
    "Peda": ("SWEETS_PACKED", "own", True),
    "Sweets": ("SWEETS_PACKED", "own", True),
    "UDDCounter": ("SWEETS_COUNTER", "own", True),
    "UDDBakery": ("BAKERY", "own", True),
    "UDDNamkeen": ("NAMKEEN", "own", True),
    "Frozen": ("FROZEN", "resale", True),
    "Third Party": ("THIRD_PARTY", "resale", True),
    "Procurement": ("PROCUREMENT", "supply", False),
    "Xpired": ("THIRD_PARTY", "resale", False),
}

# Provisional HSN / GST by KwikERP category. GST rates were revised from
# 22 Sep 2025; every value here must be confirmed by the accountant before
# go-live (gst_status = 'verify').
TAX = {
    "MILK": ("0401", 0),
    "DAHI": ("0403", 5),
    "DAHI_BULK": ("0403", 5),
    "LASSI": ("0403", 5),
    "FLAV_MILK": ("2202", 5),
    "PANEER": ("0406", 0),
    "GHEE": ("0405", 5),
    "KHOA": ("0402", 5),
    "SWEETS_PACKED": ("2106", 5),
    "SWEETS_COUNTER": ("2106", 5),
    "BAKERY": ("1905", 5),
    "NAMKEEN": ("2106", 5),
    "FROZEN": ("0710", 5),
    "THIRD_PARTY": ("", None),
    "PROCUREMENT": ("", None),
}
TAX_BY_NAME = [  # (regex on name, hsn, gst) – overrides category default
    (r"French Fries", "2004", 5),
    (r"Soya Chaap", "2106", 5),
    (r"TP Btr", "0405", 5),
    (r"TP Cream", "0401", 5),
    (r"TP Mayo", "2103", 5),
    (r"TP Wtr", "2201", 5),
    (r"Rabdi", "0402", 5),
]

# Shelf life (days) by category, from the Aug 2025 franchise list where stated.
SHELF = {"MILK": 2, "DAHI": 7, "DAHI_BULK": 7, "GHEE": 180,
         "SWEETS_COUNTER": 4, "NAMKEEN": 1, "BAKERY": 3}

# Pack conversions where the sheet's unit is a multi-pack.
# name pattern -> (base unit, base-units per sheet unit, base-unit label)
# Inferred from consumer price / known single-unit MRP; marked 'verify'.
PACKS = [
    (r"^Milk (Cow|Gold|Standard|Toned) H", "PC", 2, "500 ml pouch; sheet price is per litre"),
    (r"^Milk Cow 1L", "PC", 1, "1 L pouch; sheet price is per litre"),
    (r"^Dahi 200g Tray", "PC", 6, "tray of 6 x 200 g (Rs 180 = 6 x 30)"),
    (r"^Dahi 70g", "PC", 6, "tray of 6 x 70 g cups (Rs 72 = 6 x 12)"),
    (r"^Dahi Misti", "PC", 6, "tray of 6 cups (Rs 72 = 6 x 12)"),
    (r"^Rabdi 80g", "PC", 6, "tray of 6 x 80 g (Rs 150 = 6 x 25)"),
    (r"^Lassi Box", "PC", 18, "box of 18 x 200 ml glass (Rs 396 = 18 x 22)"),
    (r"^FM Kesar", "PC", 28, "box of 28 x 150 ml bottle (Rs 700 = 28 x 25)"),
    (r"^Peda 100g", "PC", 10, "100 g pack; sheet price is per kg"),
    (r"^Peda 250g", "PC", 4, "250 g pack; sheet price is per kg"),
    (r"^TP Wtr 1000ml", "PC", 12, "box of 12 x 1 L (Rs 240 = 12 x 20)"),
    (r"^TP Wtr 500ml", "PC", 24, "box of 24 x 500 ml (Rs 240 = 24 x 10)"),
]

# Known questionable entries in the sheet (kept as-is, flagged).
CHECKS = {
    "106": "Distributor rate Rs 20 vs Rs 510 elsewhere",
    "104": "SpecialRate2 Rs 19 vs Rs 410 elsewhere",
    "73": "Reorder level 10,000",
    "21": "Retailer and distributor both Rs 410",
}

UNIT_NORMAL = {"pc": "PC", "kg": "KG", "liter": "L", "tray": "TRAY", "tr": "TRAY", "box": "BOX"}


def num(s):
    s = (s or "").replace(",", "").strip()
    return float(s) if s else None


def main():
    rows = list(csv.DictReader(SRC.open()))
    items, prices = [], []
    for r in rows:
        code = r["ProdID"].strip()
        name = re.sub(r"\s+", " ", r["ProdName"]).strip()
        cat, kind, on_pos = CATEGORY[r["Category"].strip()]
        sheet_unit = UNIT_NORMAL[r["MyUnit"].strip().lower()]
        notes = []

        # Base unit and pack conversion
        base_unit, factor, pack_note = sheet_unit, 1, ""
        for pat, bu, f, note in PACKS:
            if re.search(pat, name):
                base_unit, factor, pack_note = bu, f, note
                break
        if sheet_unit == "KG" and not pack_note:
            # Loose items by weight (counter sweets, loose paneer) stay in KG.
            # Fixed-weight packs listed in kg are treated as one piece.
            if re.search(r"\b\d+\s?(g|kg)\b", name, re.I):
                base_unit, factor, pack_note = "PC", 1, "fixed pack listed in kg; treated as 1 piece"
        sold_by_weight = base_unit == "KG"

        hsn, gst = TAX[cat]
        for pat, h, g in TAX_BY_NAME:
            if re.search(pat, name):
                hsn, gst = h, g
                break
        if r["Category"].strip() == "Xpired":
            notes.append("discontinued (category Xpired) - imported inactive")
        if code in CHECKS:
            notes.append("CHECK: " + CHECKS[code])

        items.append({
            "code": code,
            "name": name,
            "sheet_category": r["Category"].strip(),
            "category_code": cat,
            "kind": kind,
            "base_unit": base_unit,
            "sold_by_weight": "Y" if sold_by_weight else "N",
            "trade_unit": sheet_unit,
            "trade_factor": factor,
            "pack_note": pack_note,
            "pack_status": "verify" if pack_note and factor != 1 else "",
            "hsn": hsn,
            "gst_rate": "" if gst is None else gst,
            "gst_status": "verify",
            "shelf_life_days": SHELF.get(cat, ""),
            "order_multiple": num(r["Multiple"]) or 1,
            "reorder_level": num(r["ReOrderLevel"]),
            "is_active": "N" if r["Category"].strip() == "Xpired" else "Y",
            "show_on_pos": "Y" if on_pos and r["Category"].strip() != "Xpired" else "N",
            "notes": "; ".join(notes),
        })

        for col, level in LEVELS.items():
            p = num(r[col])
            if p is None:
                continue
            # Price as given, on the sheet's unit
            prices.append({"item_code": code, "unit": sheet_unit, "level": level,
                           "price": round(p, 2), "valid_from": PRICE_DATE,
                           "source": "sheet"})
            # Derived base-unit price when the sheet prices another unit
            if base_unit != sheet_unit:
                prices.append({"item_code": code, "unit": base_unit, "level": level,
                               "price": round(p / factor, 2), "valid_from": PRICE_DATE,
                               "source": f"derived: {p:g} / {factor}"})

    with OUT_ITEMS.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(items[0].keys()))
        w.writeheader()
        w.writerows(items)
    with OUT_PRICES.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(prices[0].keys()))
        w.writeheader()
        w.writerows(prices)
    print(f"{len(items)} items, {len(prices)} prices")


if __name__ == "__main__":
    main()
