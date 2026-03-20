"""WebSocket endpoint for real-time updates."""

import asyncio

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

router = APIRouter()

# Active connections
_active_connections: list[WebSocket] = []


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    """WebSocket endpoint for real-time workout updates."""

    await websocket.accept()
    _active_connections.append(websocket)

    try:
        # Keep connection alive
        while True:
            try:
                data = await asyncio.wait_for(
                    websocket.receive_json(),
                    timeout=5.0
                )
            except asyncio.TimeoutError:
                await websocket.ping()
                continue

            # Handle message types
            if data.get("type") == "ping":
                await websocket.send_json({"type": "pong"})

    except WebSocketDisconnect:
        pass
    except Exception as e:
        print(f"WebSocket error: {e}")
    finally:
        if websocket in _active_connections:
            _active_connections.remove(websocket)
