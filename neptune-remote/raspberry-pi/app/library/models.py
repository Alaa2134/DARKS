"""Pydantic models for the model library, collections and products."""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field

# Categories the app ships with. Users can add their own free-form categories.
BUILTIN_CATEGORIES: List[Dict[str, str]] = [
    {"id": "office", "name_ar": "مكتب", "name_en": "Office", "icon": "briefcase"},
    {"id": "home", "name_ar": "منزل", "name_en": "Home", "icon": "house"},
    {"id": "kitchen", "name_ar": "مطبخ", "name_en": "Kitchen", "icon": "fork.knife"},
    {"id": "toys", "name_ar": "ألعاب", "name_en": "Toys", "icon": "gamecontroller"},
    {"id": "robotics", "name_ar": "روبوتات", "name_en": "Robotics", "icon": "cpu"},
    {"id": "electronics", "name_ar": "إلكترونيات", "name_en": "Electronics", "icon": "bolt.circle"},
    {"id": "keychains", "name_ar": "ميداليات", "name_en": "Keychains", "icon": "key"},
    {"id": "stands", "name_ar": "حوامل", "name_en": "Stands", "icon": "iphone.gen3"},
    {"id": "organizers", "name_ar": "منظمات", "name_en": "Organizers", "icon": "tray.2"},
    {"id": "decor", "name_ar": "ديكور", "name_en": "Decor", "icon": "sparkles"},
    {"id": "spare_parts", "name_ar": "قطع غيار", "name_en": "Spare parts", "icon": "wrench.and.screwdriver"},
    {"id": "projects", "name_ar": "مشاريع", "name_en": "Projects", "icon": "lightbulb"},
    {"id": "other", "name_ar": "أخرى", "name_en": "Other", "icon": "square.grid.2x2"},
]

BUILTIN_COLLECTIONS: List[Dict[str, str]] = [
    {"id": "favourites", "name_ar": "المفضلة", "name_en": "Favourites", "icon": "star.fill"},
    {"id": "print_later", "name_ar": "للطباعة لاحقاً", "name_en": "Print later", "icon": "clock"},
    {"id": "products", "name_ar": "منتجات للبيع", "name_en": "Products for sale", "icon": "tag"},
    {"id": "robotics", "name_ar": "مشاريع الروبوتات", "name_en": "Robotics projects", "icon": "cpu"},
    {"id": "gifts", "name_ar": "هدايا", "name_en": "Gifts", "icon": "gift"},
    {"id": "quick_prints", "name_ar": "طباعة سريعة", "name_en": "Quick prints", "icon": "bolt"},
    {"id": "printer_parts", "name_ar": "قطع للطابعة", "name_en": "Printer parts", "icon": "printer"},
]


class LibraryGCode(BaseModel):
    id: str
    item_id: str
    filename: str
    path: str = ""
    moonraker_path: Optional[str] = None
    material: str = ""
    quality: str = ""
    layer_height: Optional[float] = None
    estimated_seconds: Optional[float] = None
    filament_g: Optional[float] = None
    layer_count: Optional[int] = None
    profile: Dict[str, Any] = Field(default_factory=dict)
    created_at: float = 0.0


class LibraryPhoto(BaseModel):
    id: str
    item_id: str
    path: str
    caption: str = ""
    created_at: float = 0.0


class LibraryItem(BaseModel):
    id: str
    name_ar: str = ""
    name_en: str = ""
    aliases: List[str] = Field(default_factory=list)
    tags: List[str] = Field(default_factory=list)
    category: str = "other"
    notes: str = ""

    thumbnail: Optional[str] = None
    hero_image: Optional[str] = None

    model_path: Optional[str] = None
    model_filename: str = ""
    model_size: int = 0

    dimensions_x: Optional[float] = None
    dimensions_y: Optional[float] = None
    dimensions_z: Optional[float] = None
    triangle_count: Optional[int] = None

    recommended_material: str = ""
    estimated_seconds: Optional[float] = None
    estimated_filament_g: Optional[float] = None

    #: Where this model came from, when it was imported from a link rather than
    #: uploaded. Kept so the source can be reopened and the licence honoured.
    source_url: str = ""
    author: str = ""
    licence: str = ""

    favourite: bool = False
    print_count: int = 0
    last_printed: Optional[float] = None
    successful_profile: Optional[Dict[str, Any]] = None
    is_product: bool = False

    created_at: float = 0.0
    updated_at: float = 0.0

    gcodes: List[LibraryGCode] = Field(default_factory=list)
    photos: List[LibraryPhoto] = Field(default_factory=list)
    collections: List[str] = Field(default_factory=list)

    @property
    def display_name(self) -> str:
        return self.name_ar or self.name_en or self.model_filename or self.id


class LibraryItemCreate(BaseModel):
    name_ar: str = ""
    name_en: str = ""
    aliases: List[str] = Field(default_factory=list)
    tags: List[str] = Field(default_factory=list)
    category: str = "other"
    notes: str = ""
    recommended_material: str = ""
    favourite: bool = False
    source_url: str = ""
    author: str = ""
    licence: str = ""


class LibraryItemUpdate(BaseModel):
    name_ar: Optional[str] = None
    name_en: Optional[str] = None
    aliases: Optional[List[str]] = None
    tags: Optional[List[str]] = None
    category: Optional[str] = None
    notes: Optional[str] = None
    recommended_material: Optional[str] = None
    favourite: Optional[bool] = None
    is_product: Optional[bool] = None
    estimated_seconds: Optional[float] = None
    estimated_filament_g: Optional[float] = None


class SearchResult(BaseModel):
    item: LibraryItem
    score: float
    reasons: List[str] = Field(default_factory=list)


class SearchResponse(BaseModel):
    query: str
    normalized_query: str
    results: List[SearchResult] = Field(default_factory=list)
    total: int = 0
    suggestions: List[str] = Field(default_factory=list)


class Collection(BaseModel):
    id: str
    name_ar: str
    name_en: str = ""
    builtin: bool = False
    icon: str = "folder"
    item_count: int = 0
    created_at: float = 0.0


class CategoryInfo(BaseModel):
    id: str
    name_ar: str
    name_en: str
    icon: str
    item_count: int = 0


class IdeaRequest(BaseModel):
    room: Optional[str] = None
    max_seconds: Optional[float] = None
    material: Optional[str] = None
    limit: int = 12


class PrintRating(BaseModel):
    history_id: int
    item_id: Optional[str] = None
    rating: str  # excellent | good | problem
    profile: Dict[str, Any] = Field(default_factory=dict)
    note: str = ""
    created_at: float = 0.0
