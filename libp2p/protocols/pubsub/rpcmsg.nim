## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import sequtils
import chronos, nimcrypto/sysrand, chronicles
import ../../peerinfo, 
       ../../peer,
       ../../crypto/crypto,
       ../../protobuf/minprotobuf

logScope:
  topic = "RpcMsg"

const SignPrefix = "libp2p-pubsub:"

type
    SubOpts* = object
      subscribe*: bool
      topic*: string

    Message* = object
      fromPeer*: seq[byte]
      data*: seq[byte]
      seqno*: seq[byte]
      topicIDs*: seq[string]
      signature*: seq[byte]
      key*: seq[byte]

    RPCMsg* = object
      subscriptions*: seq[SubOpts]
      messages*: seq[Message]

proc encodeMessage(msg: Message, buff: var ProtoBuffer) {.gcsafe.} = 
  buff.write(initProtoField(1, msg.fromPeer))
  buff.write(initProtoField(2, msg.data))
  buff.write(initProtoField(3, msg.seqno))

  for t in msg.topicIDs:
    buff.write(initProtoField(4, t))

  buff.write(initProtoField(5, msg.signature))
  buff.write(initProtoField(6, msg.key))

  buff.finish()

proc encodeSubs(subs: SubOpts, buff: var ProtoBuffer) {.gcsafe.} = 
  buff.write(initProtoField(1, subs.subscribe))
  buff.write(initProtoField(2, subs.topic))

proc encodeRpcMsg*(msg: RPCMsg): ProtoBuffer {.gcsafe.} = 
  result = initProtoBuffer({WithVarintLength})  
  debug "encoding msg: ", msg = msg

  if msg.subscriptions.len > 0:
    var subs = initProtoBuffer()
    for s in msg.subscriptions:
      encodeSubs(s, subs)

    subs.finish()
    result.write(initProtoField(1, subs))

  if msg.messages.len > 0:
    var messages = initProtoBuffer()
    for m in msg.messages:
      encodeMessage(m, messages)

    messages.finish()
    result.write(initProtoField(2, messages))

  result.finish()

proc decodeRpcMsg*(msg: seq[byte]): RPCMsg {.gcsafe.} = 
  var pb = initProtoBuffer(msg)

  result.subscriptions = newSeq[SubOpts]()
  while true:
    # decode SubOpts array
    var field = pb.enterSubMessage()
    debug "processing submessage", field = field
    case field:
    of 0: 
      break
    of 1:
      while true:
        var subOpt: SubOpts
        var subscr: int
        discard pb.getVarintValue(1, subscr)
        subOpt.subscribe = cast[bool](subscr)
        debug "read subscribe field", subscribe = subOpt.subscribe

        if pb.getString(2, subOpt.topic) < 0:
          break
        debug "read subscribe field", topicName = subOpt.topic

        result.subscriptions.add(subOpt)
      debug "got subscriptions", subscriptions = result.subscriptions

    of 2:
      result.messages = newSeq[Message]()
      # TODO: which of this fields are really optional?
      while true:
        var msg: Message
        if pb.getBytes(1, msg.fromPeer) < 0:
          break
        debug "read message field", fromPeer = msg.fromPeer

        if pb.getBytes(2, msg.data) < 0:
          break
        debug "read message field", data = msg.data

        if pb.getBytes(3, msg.seqno) < 0:
          break
        debug "read message field", seqno = msg.seqno

        var topic: string
        while true:
          if pb.getString(4, topic) < 0:
            break
          msg.topicIDs.add(topic)
          debug "read message field", topicName = topic
          topic = ""
        
        discard pb.getBytes(5, msg.signature)
        debug "read message field", signature = msg.signature

        discard pb.getBytes(6, msg.key)
        debug "read message field", key = msg.key

        result.messages.add(msg)
    else: 
      raise newException(CatchableError, "message type not recognizedd")

var prefix {.threadvar.}: seq[byte]
proc getPreix(): var seq[byte] = 
  if prefix.len == 0:
    prefix = cast[seq[byte]](SignPrefix)
  result = prefix

proc sign*(peerId: PeerID, msg: Message): Message = 
  var buff = initProtoBuffer()
  encodeMessage(msg, buff)
  if buff.buffer.len > 0:
    result = msg
    result.signature = peerId.
                       privateKey.
                       sign(getPreix() & buff.buffer).
                       getBytes()

proc makeMessage*(peerId: PeerID, 
                  data: seq[byte], 
                  name: string): 
                  Message {.gcsafe.} = 
  var seqno: seq[byte] = newSeq[byte](20)
  if randomBytes(addr seqno[0], 20) > 0:
    result = Message(fromPeer: peerId.getBytes(), 
                     data: data, 
                     seqno: seqno, 
                     topicIDs: @[name], 
                     signature: @[],
                     key: peerId.publicKey.getRawBytes())
    result = sign(peerId, result)
