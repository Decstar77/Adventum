package main

import "core:fmt"
import "core:os"

import enet "vendor:ENet"

PORT :: u16(7777)
MAX_CLIENTS :: uint(32)
CHANNELS :: uint(2)

main :: proc() {
	if enet.initialize() != 0 {
		fmt.eprintln("ENet: initialize failed")
		os.exit(1)
	}
	defer enet.deinitialize()

	addr: enet.Address
	addr.host = enet.HOST_ANY
	addr.port = PORT

	host := enet.host_create(&addr, MAX_CLIENTS, CHANNELS, 0, 0)
	if host == nil {
		fmt.eprintln("ENet: host_create failed (port in use?)")
		os.exit(1)
	}
	defer enet.host_destroy(host)

	fmt.printfln("server: listening on 0.0.0.0:%d", PORT)

	event: enet.Event
	for {
		// Block up to 1s waiting for events.
		r := enet.host_service(host, &event, 1000)
		if r < 0 {
			fmt.eprintln("ENet: host_service error")
			break
		}
		if r == 0 {
			continue
		}

		#partial switch event.type {
		case .CONNECT:
			fmt.printfln(
				"server: client connected from %d.%d.%d.%d:%d",
				(event.peer.address.host) & 0xff,
				(event.peer.address.host >> 8) & 0xff,
				(event.peer.address.host >> 16) & 0xff,
				(event.peer.address.host >> 24) & 0xff,
				event.peer.address.port,
			)

		case .RECEIVE:
			data := event.packet.data[:event.packet.dataLength]
			msg := string(data)
			fmt.printfln("server: client -> %s", msg)

			// Echo back with a prefix.
			reply := fmt.tprintf("ack: %s", msg)
			pkt := enet.packet_create(raw_data(reply), len(reply), {.RELIABLE})
			enet.peer_send(event.peer, event.channelID, pkt)

			enet.packet_destroy(event.packet)

		case .DISCONNECT:
			fmt.println("server: client disconnected")
		}
	}
}
