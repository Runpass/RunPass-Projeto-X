"""Redes sociais do organizador de uma corrida: perfil de Instagram, Pagina de Facebook e UM post para exibir.

So aceita enderecos https dos dominios da Meta com a forma esperada, e devolve a forma normalizada. Nada aqui
chama a Meta: sao links guardados na corrida e conferidos por uma pessoa. O post so e MOSTRADO no app pelo
embed oficial (oEmbed); a RunPass nao guarda a foto, a legenda nem outros dados do post.
"""

import re
from urllib.parse import parse_qs, urlparse

_INSTAGRAM_RESERVADOS = {
    "p", "reel", "reels", "explore", "accounts", "stories", "tv", "direct", "about", "legal",
    "developer", "share", "web", "challenge", "directory", "privacy", "terms",
}  # fmt: skip
_FACEBOOK_RESERVADOS = {
    "sharer", "sharer.php", "share.php", "share", "dialog", "plugins", "tr", "login", "login.php",
    "events", "groups", "watch", "marketplace", "gaming", "help", "policies", "privacy", "business",
    "pages", "public", "hashtag", "photo", "photo.php", "permalink.php", "story.php", "reel", "video",
}  # fmt: skip
_USUARIO_INSTAGRAM = re.compile(r"^[A-Za-z0-9._]{1,30}$")
_PAGINA_FACEBOOK = re.compile(r"^[A-Za-z0-9.\-]{5,50}$")
_CODIGO = re.compile(r"^[A-Za-z0-9_\-]{5,40}$")
_ID_NUMERICO = re.compile(r"^\d{5,30}$")


def _partes(url, hosts):
    """(partes_do_caminho, consulta) se for https, sem credenciais e de um dos hosts; senao None."""
    if not isinstance(url, str) or len(url) > 500:
        return None
    try:
        alvo = urlparse(url.strip())
    except ValueError:
        return None
    if alvo.scheme != "https" or alvo.username or alvo.password:
        return None
    host = (alvo.hostname or "").lower().removeprefix("www.").removeprefix("m.")
    if host not in hosts:
        return None
    return [p for p in alvo.path.split("/") if p], parse_qs(alvo.query)


def instagram_profile(url):
    """`https://www.instagram.com/<usuario>/` ou None (post, reel, institucional e outros dominios nao valem)."""
    achado = _partes(url, {"instagram.com"})
    if not achado or len(achado[0]) != 1:
        return None
    nome = achado[0][0]
    if _USUARIO_INSTAGRAM.match(nome) and nome.lower() not in _INSTAGRAM_RESERVADOS:
        return f"https://www.instagram.com/{nome}/"
    return None


def facebook_page(url):
    """`https://www.facebook.com/<pagina>` ou None (compartilhar, eventos, grupos... nao valem)."""
    achado = _partes(url, {"facebook.com", "fb.com"})
    if not achado:
        return None
    partes = achado[0]
    if partes[:1] == ["pg"]:
        partes = partes[1:2]
    if len(partes) != 1:
        return None
    nome = partes[0]
    if _PAGINA_FACEBOOK.match(nome) and nome.lower() not in _FACEBOOK_RESERVADOS:
        return f"https://www.facebook.com/{nome}"
    return None


def embeddable_post(url):
    """(rede, url_normalizada) de um post que o embed oficial da Meta exibe, ou None.

    Instagram: `/p/<codigo>/`, `/reel/<codigo>/` ou `/tv/<codigo>/`. Facebook: `/<pagina>/posts/<id>`,
    `/<pagina>/videos/<id>` ou `/reel/<id>`."""
    achado = _partes(url, {"instagram.com"})
    if achado:
        partes = achado[0]
        if len(partes) == 2 and partes[0] in ("p", "reel", "tv") and _CODIGO.match(partes[1]):
            return "instagram", f"https://www.instagram.com/{partes[0]}/{partes[1]}/"
        return None
    achado = _partes(url, {"facebook.com", "fb.com"})
    if achado:
        partes = achado[0]
        if len(partes) == 2 and partes[0] == "reel" and _ID_NUMERICO.match(partes[1]):
            return "facebook", f"https://www.facebook.com/reel/{partes[1]}"
        if (
            len(partes) == 3
            and partes[1] in ("posts", "videos")
            and _PAGINA_FACEBOOK.match(partes[0])
            and (_ID_NUMERICO.match(partes[2]) or partes[2].startswith("pfbid"))
        ):
            return "facebook", f"https://www.facebook.com/{partes[0]}/{partes[1]}/{partes[2]}"
    return None


def check_profile(kind, value):
    """Normaliza (instagram|facebook) ou levanta ValueError. Valor vazio/None = sem rede."""
    if value in (None, ""):
        return None
    out = (instagram_profile if kind == "instagram" else facebook_page)(value)
    if out is None:
        raise ValueError(f"Endereco de {kind} invalido: use o perfil do organizador")
    return out


def check_post(value):
    if value in (None, ""):
        return None
    out = embeddable_post(value)
    if out is None:
        raise ValueError("Post invalido: use o endereco de um post, reel ou video publico")
    return out[1]
