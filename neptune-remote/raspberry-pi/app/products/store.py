"""Products: a library item turned into something you sell."""

from __future__ import annotations

import time
import uuid
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field

from ..db import Database, dump_json, load_json


class Product(BaseModel):
    id: str
    item_id: Optional[str] = None
    name_ar: str = ""
    name_en: str = ""
    sku: str = ""
    image: Optional[str] = None
    material: str = "PLA"
    colors: List[str] = Field(default_factory=list)
    print_cost: float = 0.0
    selling_price: float = 0.0
    currency: str = "EGP"
    made_to_order: bool = True
    stock: int = 0
    notes: str = ""
    created_at: float = 0.0
    updated_at: float = 0.0

    @property
    def margin(self) -> float:
        return self.selling_price - self.print_cost

    @property
    def margin_percent(self) -> float:
        if self.print_cost <= 0:
            return 0.0
        return (self.selling_price - self.print_cost) / self.print_cost * 100.0


class ProductCreate(BaseModel):
    item_id: Optional[str] = None
    name_ar: str = ""
    name_en: str = ""
    sku: str = ""
    material: str = "PLA"
    colors: List[str] = Field(default_factory=list)
    print_cost: float = 0.0
    selling_price: float = 0.0
    currency: str = "EGP"
    made_to_order: bool = True
    stock: int = 0
    notes: str = ""


class ProductUpdate(BaseModel):
    name_ar: Optional[str] = None
    name_en: Optional[str] = None
    sku: Optional[str] = None
    material: Optional[str] = None
    colors: Optional[List[str]] = None
    print_cost: Optional[float] = None
    selling_price: Optional[float] = None
    currency: Optional[str] = None
    made_to_order: Optional[bool] = None
    stock: Optional[int] = None
    notes: Optional[str] = None
    image: Optional[str] = None


class ProductStore:
    def __init__(self, database: Database) -> None:
        self.db = database

    def create(self, payload: ProductCreate) -> Product:
        product_id = uuid.uuid4().hex[:12]
        now = time.time()

        image: Optional[str] = None
        if payload.item_id:
            row = self.db.query_one(
                "SELECT hero_image, thumbnail, name_ar, name_en FROM library_items WHERE id = ?",
                (payload.item_id,),
            )
            if row is not None:
                image = row["hero_image"] or row["thumbnail"]
                if not payload.name_ar:
                    payload.name_ar = row["name_ar"] or ""
                if not payload.name_en:
                    payload.name_en = row["name_en"] or ""

        self.db.execute(
            """
            INSERT INTO products(
                id, item_id, name_ar, name_en, sku, image, material, colors,
                print_cost, selling_price, currency, made_to_order, stock, notes,
                created_at, updated_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                product_id, payload.item_id, payload.name_ar, payload.name_en, payload.sku,
                image, payload.material, dump_json(payload.colors), payload.print_cost,
                payload.selling_price, payload.currency, int(payload.made_to_order),
                payload.stock, payload.notes, now, now,
            ),
        )
        if payload.item_id:
            self.db.execute(
                "UPDATE library_items SET is_product = 1, updated_at = ? WHERE id = ?",
                (now, payload.item_id),
            )
            self.db.execute(
                "INSERT OR IGNORE INTO collection_items(collection_id, item_id, added_at) "
                "VALUES ('products', ?, ?)",
                (payload.item_id, now),
            )

        product = self.get(product_id)
        assert product is not None
        return product

    def get(self, product_id: str) -> Optional[Product]:
        row = self.db.query_one("SELECT * FROM products WHERE id = ?", (product_id,))
        return self._row(row) if row else None

    def list(self) -> List[Product]:
        return [self._row(row) for row in self.db.query("SELECT * FROM products ORDER BY updated_at DESC")]

    def update(self, product_id: str, payload: ProductUpdate) -> Optional[Product]:
        product = self.get(product_id)
        if product is None:
            return None
        for key, value in payload.model_dump(exclude_none=True).items():
            setattr(product, key, value)
        product.updated_at = time.time()

        self.db.execute(
            """
            UPDATE products SET name_ar=?, name_en=?, sku=?, image=?, material=?, colors=?,
                print_cost=?, selling_price=?, currency=?, made_to_order=?, stock=?, notes=?,
                updated_at=? WHERE id=?
            """,
            (
                product.name_ar, product.name_en, product.sku, product.image, product.material,
                dump_json(product.colors), product.print_cost, product.selling_price,
                product.currency, int(product.made_to_order), product.stock, product.notes,
                product.updated_at, product_id,
            ),
        )
        return self.get(product_id)

    def delete(self, product_id: str) -> bool:
        product = self.get(product_id)
        if product is None:
            return False
        self.db.execute("DELETE FROM products WHERE id = ?", (product_id,))
        if product.item_id:
            remaining = self.db.query_one(
                "SELECT COUNT(*) AS total FROM products WHERE item_id = ?", (product.item_id,)
            )
            if remaining is not None and int(remaining["total"] or 0) == 0:
                self.db.execute(
                    "UPDATE library_items SET is_product = 0 WHERE id = ?", (product.item_id,)
                )
        return True

    def summary(self) -> Dict[str, Any]:
        products = self.list()
        return {
            "count": len(products),
            "total_stock": sum(product.stock for product in products),
            "average_margin_percent": round(
                sum(product.margin_percent for product in products) / len(products), 1
            ) if products else 0.0,
            "potential_revenue": round(
                sum(product.selling_price * max(product.stock, 1) for product in products), 2
            ),
        }

    @staticmethod
    def _row(row: Any) -> Product:
        data = dict(row)
        data["colors"] = load_json(data["colors"], [])
        data["made_to_order"] = bool(data["made_to_order"])
        return Product(**data)
