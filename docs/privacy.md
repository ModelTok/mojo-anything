# Privacy

mojo-anything runs on your machine. The CLI, the MCP server and the skill send none of your code,
recordings or results anywhere, collect no telemetry, and need no account.

What does reach the network is what you or your agent run: pixi downloads Mojo and the packages a
unit pins (EmberJson) the first time a unit is built, `npm`, `pip` and the other package managers
install what the original needs, and the npm launcher downloads the mojo-anything release binary
from GitHub on its first run. Your agent's model provider sees what your agent sends it, under its
own policy.

Questions: [open an issue](https://github.com/ModelTok/mojo-anything/issues).
