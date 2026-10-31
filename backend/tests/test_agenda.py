from httpx import AsyncClient
from sqlalchemy import text

from tests.test_api import meeting_payload
from tests.test_auth import BOB

AGENDA = {
    "items": [
        {"topic": "Нові тарифи Pro", "owner": "Олена", "minutes": 15},
        {"topic": "Фідбек від клієнтів", "owner": "Taras"},
        {"topic": "Що робимо з річною знижкою"},
    ],
    "action_items": [
        {"task": "Порівняння з конкурентами", "owner": "Taras", "due": "2026-10-30"},
    ],
}


async def make_meeting(client: AsyncClient) -> dict:
    response = await client.post("/api/meetings", json=meeting_payload())
    assert response.status_code == 201, response.text
    return response.json()


async def test_new_meeting_has_no_agenda(client: AsyncClient) -> None:
    meeting = await make_meeting(client)
    assert meeting["agenda"] is None


async def test_save_agenda(client: AsyncClient) -> None:
    meeting = await make_meeting(client)

    response = await client.post(f"/api/meetings/{meeting['id']}/agenda", json=AGENDA)

    assert response.status_code == 200, response.text
    agenda = response.json()["agenda"]
    assert [i["topic"] for i in agenda["items"]] == [i["topic"] for i in AGENDA["items"]]
    assert agenda["items"][1] == {"topic": "Фідбек від клієнтів", "owner": "Taras", "minutes": None}
    assert agenda["action_items"][0]["due"] == "2026-10-30"
    listed = (await client.get("/api/meetings")).json()
    assert listed[0]["agenda"] == agenda


async def test_save_replaces_agenda_and_blank_owner_is_none(client: AsyncClient) -> None:
    meeting = await make_meeting(client)
    await client.post(f"/api/meetings/{meeting['id']}/agenda", json=AGENDA)

    response = await client.post(
        f"/api/meetings/{meeting['id']}/agenda",
        json={"items": [{"topic": "  Only this  ", "owner": "  "}]},
    )

    assert response.status_code == 200, response.text
    assert response.json()["agenda"] == {
        "items": [{"topic": "Only this", "owner": None, "minutes": None}],
        "action_items": [],
    }


async def test_invalid_agendas(client: AsyncClient) -> None:
    meeting = await make_meeting(client)
    url = f"/api/meetings/{meeting['id']}/agenda"
    invalid = {
        "empty": {"items": [], "action_items": []},
        "blank topic": {"items": [{"topic": "   "}]},
        "zero minutes": {"items": [{"topic": "A", "minutes": 0}]},
        "too long": {"items": [{"topic": "A", "minutes": 481}]},
        "bad date": {"action_items": [{"task": "A", "due": "next Friday"}]},
    }
    for label, payload in invalid.items():
        response = await client.post(url, json=payload)
        assert response.status_code == 422, label


async def test_ai_suggestion_is_stored_next_to_the_agenda(client: AsyncClient, engine) -> None:
    meeting = await make_meeting(client)
    suggestion = {
        "agenda": {"items": [{"topic": "нові тарифи Pro", "owner": "Олена"}], "language": "uk"},
        "text": "Пн 10:00, синк по прайсингу. 1) нові тарифи Pro — Олена",
        "model": "anthropic.claude-opus-5-5",
        "prompt_version": "agenda-v1",
    }

    response = await client.post(
        f"/api/meetings/{meeting['id']}/agenda", json={**AGENDA, "ai_suggestion": suggestion}
    )

    assert response.status_code == 200, response.text
    assert "ai_suggestion" not in response.json()
    async with engine.connect() as conn:
        stored = (
            await conn.execute(
                text("SELECT ai_suggestion FROM meetings WHERE id = :id"), {"id": meeting["id"]}
            )
        ).scalar_one()
    assert stored["model"] == "anthropic.claude-opus-5-5"
    assert stored["prompt_version"] == "agenda-v1"
    assert stored["agenda"] == suggestion["agenda"]
    assert stored["text"] == suggestion["text"]
    assert "saved_at" in stored


async def test_delete_agenda(client: AsyncClient) -> None:
    meeting = await make_meeting(client)
    await client.post(f"/api/meetings/{meeting['id']}/agenda", json=AGENDA)

    response = await client.delete(f"/api/meetings/{meeting['id']}/agenda")

    assert response.status_code == 200
    assert response.json()["agenda"] is None


async def test_cannot_touch_someone_elses_agenda(client: AsyncClient) -> None:
    meeting = await make_meeting(client)
    url = f"/api/meetings/{meeting['id']}/agenda"
    assert (await client.post(url, json=AGENDA, headers=BOB)).status_code == 404
    assert (await client.delete(url, headers=BOB)).status_code == 404
