"""Baixa imagem com protecao de rede: so https, so destino publico, limites de redirecionamento e tamanho."""

import io
import unittest

from PIL import Image
from runpass.admin_banners import Blocked, fetch_image
from runpass.service import Problem


def png(color=(10, 120, 200)):
    out = io.BytesIO()
    Image.new("RGB", (64, 36), color).save(out, format="PNG")
    return out.getvalue()


class Transport:
    """Respostas combinadas por URL: (status, headers, corpo) ou excecao."""

    def __init__(self, respostas):
        self.respostas, self.vistas = respostas, []

    def __call__(self, url):
        self.vistas.append(url)
        r = self.respostas[url]
        if isinstance(r, Exception):
            raise r
        return r


class FetchImageTests(unittest.TestCase):
    def codigo(self, url, transport):
        with self.assertRaises(Problem) as ctx:
            fetch_image(url, transport)
        return ctx.exception.code

    def test_baixa_png_e_converte_webp_para_jpeg(self):
        t = Transport({"https://a.exemplo/x.png": (200, {"content-type": "image/png"}, png())})
        data, kind = fetch_image("https://a.exemplo/x.png", t)
        self.assertEqual(kind, "image/png")
        out = io.BytesIO()
        Image.new("RGB", (40, 40), (1, 2, 3)).save(out, format="WEBP")
        t = Transport(
            {"https://a.exemplo/x.webp": (200, {"content-type": "image/webp"}, out.getvalue())}
        )
        self.assertEqual(fetch_image("https://a.exemplo/x.webp", t)[1], "image/jpeg")

    def test_so_https_sem_credenciais_e_nunca_chama_a_rede(self):
        t = Transport({})
        for url in (
            "http://a.exemplo/x.png",
            "ftp://a.exemplo/x.png",
            "file:///etc/passwd",
            "https://user:senha@a.exemplo/x.png",
            "https:///x.png",
            "",
            "https://a.exemplo/" + "x" * 2000,
        ):
            self.assertEqual(self.codigo(url, t), "INVALID_IMAGE_URL", url)
        self.assertEqual(t.vistas, [])

    def test_destino_nao_publico_e_barrado(self):
        t = Transport({"https://interno.exemplo/x.png": Blocked()})
        self.assertEqual(self.codigo("https://interno.exemplo/x.png", t), "IMAGE_URL_BLOCKED")

    def test_redirecionamento_e_revalidado_a_cada_salto_e_tem_limite(self):
        ok = (200, {"content-type": "image/png"}, png())
        t = Transport(
            {
                "https://a.exemplo/1": (302, {"location": "/2"}, b""),
                "https://a.exemplo/2": ok,
            }
        )
        self.assertEqual(fetch_image("https://a.exemplo/1", t)[1], "image/png")
        # redirecionar para http (ou para metadados) e recusado antes de qualquer pedido
        t = Transport(
            {"https://a.exemplo/1": (302, {"location": "http://169.254.169.254/latest"}, b"")}
        )
        self.assertEqual(self.codigo("https://a.exemplo/1", t), "INVALID_IMAGE_URL")
        self.assertEqual(t.vistas, ["https://a.exemplo/1"])
        # destino do redirecionamento resolve para rede interna
        t = Transport(
            {
                "https://a.exemplo/1": (301, {"location": "https://b.exemplo/x"}, b""),
                "https://b.exemplo/x": Blocked(),
            }
        )
        self.assertEqual(self.codigo("https://a.exemplo/1", t), "IMAGE_URL_BLOCKED")
        # laco
        t = Transport(
            {f"https://a.exemplo/{i}": (302, {"location": f"/{i + 1}"}, b"") for i in range(10)}
        )
        self.assertEqual(self.codigo("https://a.exemplo/0", t), "IMAGE_FETCH_FAILED")

    def test_tipo_tamanho_e_status(self):
        for resposta, esperado in (
            ((200, {"content-type": "text/html"}, b"<html>"), "INVALID_IMAGE"),
            ((200, {"content-type": "image/png"}, b"x" * 6_000_001), "IMAGE_TOO_LARGE"),
            ((404, {}, b""), "IMAGE_FETCH_FAILED"),
            ((200, {}, png()), "INVALID_IMAGE"),
        ):
            t = Transport({"https://a.exemplo/x": resposta})
            self.assertEqual(self.codigo("https://a.exemplo/x", t), esperado)
        t = Transport({"https://a.exemplo/x": OSError("rede")})
        self.assertEqual(self.codigo("https://a.exemplo/x", t), "IMAGE_FETCH_FAILED")


if __name__ == "__main__":
    unittest.main()
