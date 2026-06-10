# FPVDrone

Simple Roblox FPV drone controller.

## Studio layout

- `src/ServerScriptService/Script.server.luau` goes in `game.ServerScriptService.Script`.
- `src/StarterPlayer/StarterPlayerScripts/DroneInputClient.client.luau` goes in `game.StarterPlayer.StarterPlayerScripts.DroneInputClient`.

The server script owns the drone physics, prompt, blade motors, character hiding, and MPH HUD. The tiny client script only reads `W`, `A`, `S`, `D`, `Q`, and `E` and sends input intent to the server.

## Controls

- `F` near the drone: enter/fly
- `W/S`: forward/back
- `A/D`: turn left/right
- `E/Q`: up/down
