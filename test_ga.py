"""Tests for GA4 host gating and HTML injection. No live API access required.

Run:  .venv/bin/python -m unittest test_ga -v
"""

import os
import unittest
from pathlib import Path
from types import SimpleNamespace

from aiohttp.test_utils import make_mocked_request

import server

ENV_KEYS = ("GA_MEASUREMENT_ID", "GA_HOSTS", "GA_DISABLE", "SITE_URL")
HTML = Path(__file__).parent / "static" / "index.html"


class _EnvRestore(unittest.TestCase):
    """Put GA env vars back after each test so order never matters."""

    def setUp(self):
        self._saved = {k: os.environ.get(k) for k in ENV_KEYS}
        for key in ENV_KEYS:
            os.environ.pop(key, None)

    def tearDown(self):
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


class GaHelperTests(_EnvRestore):
    def test_default_id_on_public_host(self):
        html = server.ga_tag_html("sakurachat.fun")
        self.assertNotIn('<script async src="https://www.googletagmanager.com/gtag/js', html)
        self.assertIn("window.loadSakuraGa", html)
        self.assertIn("window.__GA_MEASUREMENT_ID = 'G-88QWE8YM3Q'", html)
        self.assertIn("window.__GA_ENABLED = true", html)
        self.assertIn("cookie_flags: 'SameSite=Lax;Secure'", html)
        self.assertIn("allow_google_signals: false", html)
        self.assertIn("analytics_storage: 'denied'", html)
        self.assertLess(html.index("consent"), html.index("loadSakuraGa"))
        self.assertIn("sakura_consent", html)

    def test_localhost_stub_still_defines_consent_default(self):
        html = server.ga_tag_html("127.0.0.1")
        self.assertIn("gtag('consent', 'default'", html)
        self.assertIn("analytics_storage: 'denied'", html)

    def test_www_alias_is_also_production(self):
        self.assertIn("G-88QWE8YM3Q", server.ga_tag_html("www.sakurachat.fun"))

    def test_localhost_does_not_load_google(self):
        html = server.ga_tag_html("127.0.0.1")
        self.assertNotIn("googletagmanager.com", html)
        self.assertIn("window.__GA_ENABLED = false", html)

    def test_railway_preview_does_not_load_google(self):
        self.assertNotIn("googletagmanager.com", server.ga_tag_html("app.up.railway.app"))

    def test_empty_measurement_id_disables(self):
        os.environ["GA_MEASUREMENT_ID"] = ""
        self.assertEqual(server.ga_measurement_id(), "")
        self.assertNotIn("googletagmanager.com", server.ga_tag_html("sakurachat.fun"))

    def test_invalid_measurement_id_is_rejected(self):
        os.environ["GA_MEASUREMENT_ID"] = 'G-88QWE8YM3Q"><script>alert(1)</script>'
        self.assertEqual(server.ga_measurement_id(), "")
        self.assertNotIn("<script>alert", server.ga_tag_html("sakurachat.fun"))

    def test_ga_disable_overrides_public_host(self):
        os.environ["GA_DISABLE"] = "1"
        self.assertFalse(server.ga_enabled_for("sakurachat.fun"))
        self.assertNotIn("googletagmanager.com", server.ga_tag_html("sakurachat.fun"))

    def test_ga_hosts_can_allow_a_preview(self):
        os.environ["GA_HOSTS"] = "app.up.railway.app"
        self.assertTrue(server.ga_enabled_for("app.up.railway.app"))
        self.assertIn("googletagmanager.com", server.ga_tag_html("app.up.railway.app"))

    def test_connection_hostname_ignores_forwarded_host(self):
        req = SimpleNamespace(host="127.0.0.1:8787", headers={})
        self.assertEqual(server.connection_hostname(req), "127.0.0.1")
        spoofed = SimpleNamespace(
            host="127.0.0.1:8787",
            headers={"X-Forwarded-Host": "sakurachat.fun, cdn.example"},
        )
        self.assertEqual(server.connection_hostname(spoofed), "127.0.0.1")
        self.assertEqual(server.ga_eligibility_host(spoofed), "127.0.0.1")
        self.assertNotIn("loadSakuraGa", server.ga_tag_for_request(spoofed))

    def test_site_url_does_not_enable_ga_on_localhost_host(self):
        os.environ["SITE_URL"] = "https://sakurachat.fun"
        local = SimpleNamespace(host="127.0.0.1:8787", headers={})
        self.assertEqual(server.ga_eligibility_host(local), "sakurachat.fun")
        self.assertNotIn("loadSakuraGa", server.ga_tag_for_request(local))

    def test_site_url_and_matching_host_enable_loader(self):
        os.environ["SITE_URL"] = "https://sakurachat.fun"
        req = SimpleNamespace(host="sakurachat.fun", headers={})
        html = server.ga_tag_for_request(req)
        self.assertIn("loadSakuraGa", html)
        self.assertIn("G-88QWE8YM3Q", html)

    def test_index_html_has_placeholder(self):
        source = HTML.read_text(encoding="utf-8")
        self.assertIn("__GA_TAG__", source)
        self.assertIn('id="cookie-banner"', source)
        self.assertIn('data-consent="denied"', source)
        self.assertIn('data-consent="granted"', source)


class GaIndexTests(_EnvRestore, unittest.IsolatedAsyncioTestCase):
    async def test_production_index_injects_gtag(self):
        req = make_mocked_request("GET", "/", headers={"Host": "sakurachat.fun"})
        resp = await server.index(req)
        body = resp.text
        self.assertNotIn("__GA_TAG__", body)
        self.assertIn("G-88QWE8YM3Q", body)
        self.assertIn("loadSakuraGa", body)
        self.assertNotIn('<script async src="https://www.googletagmanager.com/gtag/js', body)
        self.assertIn("__GA_ENABLED = true", body)

    async def test_local_index_is_a_stub(self):
        req = make_mocked_request("GET", "/", headers={"Host": "127.0.0.1:8787"})
        resp = await server.index(req)
        body = resp.text
        self.assertNotIn("__GA_TAG__", body)
        self.assertNotIn("googletagmanager.com", body)
        self.assertIn("__GA_ENABLED = false", body)

    async def test_forwarded_host_cannot_enable_local_index(self):
        req = make_mocked_request(
            "GET",
            "/",
            headers={"Host": "127.0.0.1:8787", "X-Forwarded-Host": "sakurachat.fun"},
        )
        resp = await server.index(req)
        self.assertNotIn("loadSakuraGa", resp.text)
        self.assertIn("__GA_ENABLED = false", resp.text)


if __name__ == "__main__":
    unittest.main()
