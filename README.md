# share.lua

*share.lua* is a set of modules that aims to make it easier to make multiplayer games with Lua, especially with [LÖVE](https://love2d.org/) and [Castle](https://playcastle.io/). LÖVE provides the [lua-enet](http://leafo.net/lua-enet/) library that is used for network communication. Castle can also be used to automatically run a game server in the cloud.

Files in this repository:

- [**state.lua**](state.lua) -- A 'state' data structure that keeps track of changes to itself so that they can be sent over the network. Can store any serializable data. Every table in a state can only appear once (and thus cycles are not allowed either).
- [**tests.lua**](tests.lua) -- Tests for the state data structure.
- [**cs.lua**](cs.lua) -- 'client' and 'server' modules that allow setting up events to listen for on clients and servers and hook up state data structures for transferring data. The 'share' state can be written to by the server and read by all clients, and each client gets a 'home' state that it can write to and the server can read.
- [**example_server.lua**](example_server.lua), [**example_client.lua**](example_client.lua) -- Example usage of the 'cs' module. Start here to learn how to use these modules.
- [**example_local.lua**](example_local.lua) -- Run both the example client and the server locally in the same process for easy testing.
- [**example_castle.lua**](example_castle.lua) -- Run the example client locally and the server in the cloud using Castle.
