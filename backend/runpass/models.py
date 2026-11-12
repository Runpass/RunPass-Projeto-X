import re
from datetime import date
from decimal import Decimal, InvalidOperation
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

Username = Annotated[str, Field(min_length=3, max_length=30, pattern=r"^[A-Za-z0-9_]+$")]


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class CreateProfile(Input):
    displayName: Annotated[str, Field(min_length=1, max_length=80)]
    username: Username

    @field_validator("displayName")
    @classmethod
    def name(cls, value):
        if not value.strip():
            raise ValueError("Name required")
        return value.strip()


class PatchProfile(Input):
    expectedVersion: Annotated[int, Field(ge=1)]
    displayName: Annotated[str, Field(min_length=1, max_length=80)] | None = None
    username: Username | None = None
    city: Annotated[str, Field(max_length=100)] | None = None
    state: Annotated[str, Field(pattern=r"^[A-Z]{2}$")] | None = None
    # Centroide da cidade escolhida (app manda os dois juntos, derivados da lista do IBGE; sem
    # GPS do aparelho). So para o raio de proximidade do filtro "Minha Cidade". Decimal, nao
    # float: o DynamoDB nao grava float (mesma razao de ImportDistance/ImportEdition).
    latitude: Decimal | None = Field(default=None, ge=-90, le=90, max_digits=12, decimal_places=7)
    longitude: Decimal | None = Field(
        default=None, ge=-180, le=180, max_digits=12, decimal_places=7
    )
    bio: Annotated[str, Field(max_length=500)] | None = None
    # Data de nascimento (so o proprio titular a ve): continua valendo a regra de idade minima
    # da admissao (13 anos), conferida no servico.
    birthDate: date | None = None
    photoReference: str | None = None
    bannerReference: str | None = None
    isPrivate: bool | None = None

    @field_validator("birthDate", mode="before")
    @classmethod
    def birth_date(cls, value):
        if value is None:
            return None
        if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
            raise ValueError("Date must be YYYY-MM-DD")
        return date.fromisoformat(value)

    @field_validator("latitude", "longitude", mode="before")
    @classmethod
    def decimal_coordinate(cls, value):
        if value is None or isinstance(value, Decimal):
            return value
        try:
            return Decimal(str(value))
        except InvalidOperation as error:
            raise ValueError("Coordenada invalida") from error

    @model_validator(mode="after")
    def fields(self):
        if not self.model_fields_set - {"expectedVersion"}:
            raise ValueError("At least one change required")
        if any(
            getattr(self, f) is None
            for f in self.model_fields_set & {"displayName", "username", "isPrivate"}
        ):
            raise ValueError("Required field cannot be cleared")
        if self.displayName is not None and not self.displayName.strip():
            raise ValueError("Name required")
        return self


class Eligibility(Input):
    birthDate: date
    declaresAdult: bool

    @field_validator("declaresAdult")
    @classmethod
    def adult(cls, value):
        if value is not True:
            raise ValueError("Adult declaration required")
        return value

    @field_validator("birthDate", mode="before")
    @classmethod
    def birth_date(cls, value):
        if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
            raise ValueError("Date must be YYYY-MM-DD")
        return date.fromisoformat(value)


class PutRacePlan(Input):
    status: Literal["wanted", "registered"]
    distanceId: Annotated[str, Field(min_length=1, max_length=100)] | None = None


class CreateParticipation(Input):
    editionId: Annotated[str, Field(min_length=1, max_length=100)]
    distanceId: Annotated[str, Field(min_length=1, max_length=100)]
    timeSeconds: Annotated[int, Field(ge=1)] | None = None
    placement: Annotated[int, Field(ge=1)] | None = None
    bibNumber: Annotated[str, Field(max_length=40)] | None = None

    @field_validator("bibNumber")
    @classmethod
    def bib(cls, value):
        if value is not None and not value.strip():
            raise ValueError("Blank bib is not stored")
        return value.strip() if value is not None else None


class PatchParticipation(Input):
    expectedVersion: Annotated[int, Field(ge=1)]
    editionId: Annotated[str, Field(min_length=1, max_length=100)] | None = None
    distanceId: Annotated[str, Field(min_length=1, max_length=100)] | None = None
    timeSeconds: Annotated[int, Field(ge=1)] | None = None
    placement: Annotated[int, Field(ge=1)] | None = None
    bibNumber: Annotated[str, Field(max_length=40)] | None = None
    showTime: bool | None = None
    showPlacement: bool | None = None
    medalImageReference: Annotated[str, Field(min_length=1, max_length=200)] | None = None
    # Modelo de medalha (catalogo fixo de imagens); None volta ao padrao
    # (circular_prata_azul). Customizacao visual da legenda abaixo tambem opcional.
    medalFrameId: (
        Literal[
            "circular_prata_azul",
            "circular_rose_rosa",
            "circular_grafite_preto",
            "hexagonal_bronze_verde",
            "hexagonal_rose_lilas",
            "quadrada_rose_malva",
            "escudo_grafite_azul",
            "assimetrica_prata_lima",
            "triangular_grafite_preto",
            "triangular_rose_rosa",
        ]
        | None
    ) = None
    medalDescription: Annotated[str, Field(min_length=1, max_length=200)] | None = None
    medalCity: Annotated[str, Field(min_length=1, max_length=100)] | None = None
    medalState: Annotated[str, Field(pattern=r"^[A-Z]{2}$")] | None = None
    medalYear: Annotated[int, Field(ge=1900, le=2100)] | None = None
    # Recorte da foto so para a prateleira (reposicionamento); None volta ao
    # recorte automatico da foto oficial (medalImageReference), que nunca muda.
    medalDisplayImageReference: Annotated[str, Field(min_length=1, max_length=200)] | None = None

    @model_validator(mode="after")
    def changes(self):
        changed = self.model_fields_set - {"expectedVersion"}
        if not changed:
            raise ValueError("At least one change required")
        if any(
            getattr(self, name) is None
            for name in changed & {"editionId", "distanceId", "medalImageReference"}
        ):
            raise ValueError("Catalog references cannot be cleared")
        if "bibNumber" in changed and self.bibNumber is not None:
            if not self.bibNumber.strip():
                raise ValueError("Blank bib is not stored")
            self.bibNumber = self.bibNumber.strip()
        return self


class StartUpload(Input):
    contentType: str
    sizeBytes: Annotated[int, Field(ge=1, le=10_000_000)]

    @field_validator("contentType")
    @classmethod
    def image_type(cls, value):
        if value not in {"image/jpeg", "image/png"}:
            raise ValueError("JPEG or PNG required")
        return value


class ReviewRatings(Input):
    organization: Annotated[int, Field(ge=1, le=5)]
    course: Annotated[int, Field(ge=1, le=5)]
    kit: Annotated[int, Field(ge=1, le=5)]
    medal: Annotated[int, Field(ge=1, le=5)]
    hydration: Annotated[int, Field(ge=1, le=5)]
    facilities: Annotated[int, Field(ge=1, le=5)]
    safety: Annotated[int, Field(ge=1, le=5)]
    valueForMoney: Annotated[int, Field(ge=1, le=5)]


class CompleteParticipation(Input):
    expectedVersion: Annotated[int, Field(ge=1)]
    declaredCompleted: bool
    ratings: ReviewRatings
    medalImageReference: Annotated[str, Field(min_length=1, max_length=200)]
    publishToFeed: bool
    comment: Annotated[str, Field(max_length=2000)] | None = None

    @field_validator("declaredCompleted")
    @classmethod
    def completed(cls, value):
        if value is not True:
            raise ValueError("Completion declaration required")
        return value


class ReplaceReview(Input):
    expectedVersion: Annotated[int, Field(ge=1)]
    ratings: ReviewRatings
    comment: Annotated[str, Field(max_length=2000)] | None = None


class CreateComment(Input):
    text: Annotated[str, Field(min_length=1, max_length=1000)]
    # Resposta a um comentario (um nivel: responder a uma resposta vira resposta ao comentario raiz).
    parentId: Annotated[str, Field(min_length=1, max_length=64)] | None = None

    @field_validator("text")
    @classmethod
    def not_blank(cls, value):
        if not value.strip():
            raise ValueError("Comment cannot be blank")
        return value.strip()


class EditComment(Input):
    text: Annotated[str, Field(min_length=1, max_length=1000)]
    expectedVersion: Annotated[int, Field(ge=1)] | None = None

    @field_validator("text")
    @classmethod
    def not_blank(cls, value):
        if not value.strip():
            raise ValueError("Comment cannot be blank")
        return value.strip()


class EditionRequestFields(Input):
    """Pedido de prova ausente (contrato EditionRequestFields). `imageReference` e o banner sugerido pela pessoa
    (imagem ja enviada e tratada, so dela): nunca publica sozinho; a equipe aprova com credito e autorizacao."""

    name: Annotated[str, Field(min_length=1, max_length=160)]
    date: date
    city: Annotated[str, Field(min_length=1, max_length=100)]
    state: Annotated[str, Field(pattern=r"^[A-Za-z]{2}$")] | None = None
    distanceKm: Decimal = Field(gt=0, le=1000, max_digits=8, decimal_places=4)
    officialUrl: Annotated[str, Field(max_length=500, pattern=r"^https://[^\s]+$")] | None = None
    imageReference: Annotated[str, Field(pattern=r"^img_[a-f0-9]{64}$")] | None = None

    @field_validator("name", "city")
    @classmethod
    def text(cls, value):
        value = " ".join(value.split())
        if not value or any(ord(c) < 32 for c in value):
            raise ValueError("Text required")
        return value

    @field_validator("state")
    @classmethod
    def uf(cls, value):
        return value.upper() if value is not None else None

    @field_validator("date", mode="before")
    @classmethod
    def race_date(cls, value):
        if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
            raise ValueError("Date must be YYYY-MM-DD")
        return date.fromisoformat(value)

    @field_validator("distanceKm", mode="before")
    @classmethod
    def kilometers(cls, value):
        if isinstance(value, bool):
            raise ValueError("Distancia invalida")
        if isinstance(value, Decimal):
            return value
        if not isinstance(value, int | float):
            raise ValueError("Distancia invalida")
        try:
            return Decimal(str(value))
        except InvalidOperation as error:
            raise ValueError("Distancia invalida") from error


class PatchEditionRequest(Input):
    expectedVersion: Annotated[int, Field(ge=1)]
    name: Annotated[str, Field(min_length=1, max_length=160)] | None = None
    date: str | None = None
    city: Annotated[str, Field(min_length=1, max_length=100)] | None = None
    state: Annotated[str, Field(pattern=r"^[A-Za-z]{2}$")] | None = None
    distanceKm: Decimal | None = None
    officialUrl: Annotated[str, Field(max_length=500)] | None = None

    @model_validator(mode="after")
    def changes(self):
        fields = self.model_fields_set - {"expectedVersion"}
        if not fields or any(getattr(self, f) is None for f in fields):
            raise ValueError("At least one change required, without nulls")
        return self

    @field_validator("distanceKm", mode="before")
    @classmethod
    def kilometers(cls, value):
        return EditionRequestFields.kilometers(value) if value is not None else None


class ResubmitEditionRequest(Input):
    expectedVersion: Annotated[int, Field(ge=1)]


class ReviewRequestDecision(Input):
    expectedVersion: Annotated[int, Field(ge=1)]
    decision: Literal["approve", "link", "reject"]
    editionId: Annotated[str, Field(min_length=1, max_length=100)] | None = None
    reason: Annotated[str, Field(min_length=1, max_length=500)] | None = None

    @model_validator(mode="after")
    def consistent(self):
        if self.decision == "reject":
            if not self.reason or not self.reason.strip() or self.editionId is not None:
                raise ValueError("Reject needs a reason and no edition")
        elif not self.editionId or self.reason is not None:
            raise ValueError("Approve and link need an existing edition")
        return self
