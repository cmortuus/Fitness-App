"""Tests for settings metadata and sync behavior."""
import pytest
from httpx import AsyncClient

pytestmark = pytest.mark.asyncio(loop_scope="function")


class TestSettingsSync:
    async def test_save_settings_stamps_metadata(self, client: AsyncClient):
        r = await client.put("/api/auth/settings", json={
            "weightUnit": "lbs",
            "branchPreference": "dev",
        })
        assert r.status_code == 200, r.text
        data = r.json()
        assert data["weightUnit"] == "lbs"
        assert data["settingsMeta"]["schema_version"] == 1
        assert data["settingsMeta"]["updated_by"] == "testrunner"
        assert data["settingsMeta"]["source_device"] == "web"
        assert data["settingsMeta"]["updated_at"].endswith("Z")

    async def test_save_settings_prefers_explicit_client_name_header(self, client: AsyncClient):
        r = await client.put(
            "/api/auth/settings",
            headers={"X-Client-Name": "ios"},
            json={"weightUnit": "kg"},
        )
        assert r.status_code == 200, r.text
        assert r.json()["settingsMeta"]["source_device"] == "ios"
