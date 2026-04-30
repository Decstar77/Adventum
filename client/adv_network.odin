package main

import enet "vendor:ENet"

NET_SERVER_HOST :: "127.0.0.1"
NET_SERVER_PORT :: u16(7777)
NET_CHANNELS :: uint(2)

netHost: ^enet.Host
netPeer: ^enet.Peer
netConnected: bool

net_init :: proc() {
	if enet.initialize() != 0 {
		log_err("ENet: initialize failed")
		return
	}

	netHost = enet.host_create(nil, 1, NET_CHANNELS, 0, 0)
	if netHost == nil {
		log_err("ENet: client host_create failed")
		return
	}

	addr: enet.Address
	enet.address_set_host(&addr, NET_SERVER_HOST)
	addr.port = NET_SERVER_PORT

	netPeer = enet.host_connect(netHost, &addr, NET_CHANNELS, 0)
	if netPeer == nil {
		log_err("ENet: no available peers for connect")
		return
	}

	log_infof("ENet: connecting to %s:%d ...", NET_SERVER_HOST, NET_SERVER_PORT)
}

net_send :: proc(msg: string, channel: u8 = 0, reliable: bool = true) {
	if netPeer == nil || !netConnected {
		return
	}
	flags: enet.PacketFlags = reliable ? {.RELIABLE} : {}
	pkt := enet.packet_create(raw_data(msg), len(msg), flags)
	enet.peer_send(netPeer, channel, pkt)
}

net_update :: proc() {
	if netHost == nil {
		return
	}

	event: enet.Event
	for enet.host_service(netHost, &event, 0) > 0 {
		#partial switch event.type {
		case .CONNECT:
			netConnected = true
			log_info("ENet: connected to server")
			net_send("hello from client")

		case .RECEIVE:
			data := event.packet.data[:event.packet.dataLength]
			log_infof("ENet: server -> %s", string(data))
			enet.packet_destroy(event.packet)

		case .DISCONNECT:
			netConnected = false
			log_warn("ENet: disconnected from server")
		}
	}
}

net_shutdown :: proc() {
	if netPeer != nil {
		enet.peer_disconnect(netPeer, 0)
		event: enet.Event
		deadline := 3
		for deadline > 0 {
			r := enet.host_service(netHost, &event, 1000)
			if r <= 0 {break}
			#partial switch event.type {
			case .RECEIVE:
				enet.packet_destroy(event.packet)
			case .DISCONNECT:
				deadline = 0
			}
			deadline -= 1
		}
	}
	if netHost != nil {
		enet.host_destroy(netHost)
		netHost = nil
	}
	enet.deinitialize()
}
