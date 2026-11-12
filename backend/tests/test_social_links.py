import unittest

from runpass.social_links import (
    check_post,
    check_profile,
    embeddable_post,
    facebook_page,
    instagram_profile,
)


class SocialLinksTests(unittest.TestCase):
    def test_instagram_so_aceita_perfil_em_https(self):
        for ok in (
            "https://www.instagram.com/corrida_exemplo/",
            "https://instagram.com/corrida_exemplo",
            "https://m.instagram.com/corrida.exemplo?hl=pt",
        ):
            self.assertTrue(instagram_profile(ok), ok)
        self.assertEqual(
            instagram_profile("https://instagram.com/Corrida_Exemplo"),
            "https://www.instagram.com/Corrida_Exemplo/",
        )
        for ruim in (
            "http://www.instagram.com/corrida_exemplo/",  # sem https
            "https://www.instagram.com/p/AbC123/",  # post
            "https://www.instagram.com/explore/",
            "https://www.instagram.com/",
            "https://user:senha@www.instagram.com/x/",  # credenciais
            "https://instagram.com.malicioso.invalid/corrida/",
            "https://exemplo.org/instagram",
            "javascript:alert(1)",
            "",
            None,
            123,
        ):
            self.assertIsNone(instagram_profile(ruim), ruim)

    def test_facebook_so_aceita_pagina(self):
        self.assertEqual(
            facebook_page("https://www.facebook.com/corridaexemplo"),
            "https://www.facebook.com/corridaexemplo",
        )
        self.assertEqual(
            facebook_page("https://facebook.com/pg/corridaexemplo/posts"),
            "https://www.facebook.com/corridaexemplo",
        )
        for ruim in (
            "https://www.facebook.com/sharer/sharer.php?u=x",
            "https://www.facebook.com/events/123456",
            "https://www.facebook.com/corridaexemplo/posts/123456789",
            "https://www.facebook.com/abc",  # nome curto demais
            "https://facebook.com.malicioso.invalid/corridaexemplo",
            "http://www.facebook.com/corridaexemplo",
        ):
            self.assertIsNone(facebook_page(ruim), ruim)

    def test_post_para_exibir_so_de_formatos_do_embed_oficial(self):
        self.assertEqual(
            embeddable_post("https://www.instagram.com/p/AbC123xyz/?utm_source=ig"),
            ("instagram", "https://www.instagram.com/p/AbC123xyz/"),
        )
        self.assertEqual(
            embeddable_post("https://instagram.com/reel/Cx9_aB-12/"),
            ("instagram", "https://www.instagram.com/reel/Cx9_aB-12/"),
        )
        self.assertEqual(
            embeddable_post("https://www.facebook.com/corridaexemplo/posts/1234567890123"),
            ("facebook", "https://www.facebook.com/corridaexemplo/posts/1234567890123"),
        )
        self.assertEqual(
            embeddable_post("https://www.facebook.com/corridaexemplo/videos/1234567890"),
            ("facebook", "https://www.facebook.com/corridaexemplo/videos/1234567890"),
        )
        self.assertEqual(
            embeddable_post("https://www.facebook.com/reel/1234567890"),
            ("facebook", "https://www.facebook.com/reel/1234567890"),
        )
        for ruim in (
            "https://www.instagram.com/corrida_exemplo/",  # perfil nao e post
            "https://www.instagram.com/stories/x/123/",
            "https://www.instagram.com/p/",
            "https://www.facebook.com/corridaexemplo",
            "https://www.facebook.com/corridaexemplo/posts/",
            "https://exemplo.org/p/AbC123xyz/",
            "http://www.instagram.com/p/AbC123xyz/",
        ):
            self.assertIsNone(embeddable_post(ruim), ruim)

    def test_check_levanta_erro_e_vazio_apaga(self):
        self.assertIsNone(check_profile("instagram", None))
        self.assertIsNone(check_profile("facebook", ""))
        self.assertIsNone(check_post(""))
        with self.assertRaises(ValueError):
            check_profile("instagram", "https://exemplo.org/x")
        with self.assertRaises(ValueError):
            check_post("https://www.instagram.com/corrida_exemplo/")


if __name__ == "__main__":
    unittest.main()
