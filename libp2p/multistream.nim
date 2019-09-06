## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import sequtils, strutils, strformat
import chronos
import connection, 
       varint, 
       vbuffer, 
       protocols/protocol

const MsgSize* = 64*1024
const Codec* = "/multistream/1.0.0"
const MSCodec* = "\x13" & Codec & "\n"
const Na = "\x03na\n"
const Ls = "\x03ls\n"

type
  MultisteamSelectException = object of CatchableError
  Matcher* = proc (proto: string): bool {.gcsafe.}

  HandlerHolder* = object
    proto*: string
    protocol*: LPProtocol
    match*: Matcher

  MultisteamSelect* = ref object of RootObj
    handlers*: seq[HandlerHolder]
    codec*: string
    na: string
    ls: string

proc newMultistream*(): MultisteamSelect =
  new result
  result.codec = MSCodec
  result.ls = Ls
  result.na = Na

proc select*(m: MultisteamSelect,
             conn: Connection,
             proto: seq[string]): 
             Future[string] {.async.} =
  ## select a remote protocol
  await conn.write(m.codec) # write handshake
  if proto.len() > 0:
    await conn.writeLp((proto[0] & "\n")) # select proto

  result = cast[string](await conn.readLp()) # read ms header
  result.removeSuffix("\n")
  if result != Codec:
    return ""

  if proto.len() == 0: # no protocols, must be a handshake call
    return

  result = cast[string](await conn.readLp()) # read the first proto
  result.removeSuffix("\n")
  if result == proto[0]:
    return

  if not result.len > 0:
    for p in proto[1..<proto.len()]:
      await conn.writeLp((p & "\n")) # select proto
      result = cast[string](await conn.readLp()) # read the first proto
      result.removeSuffix("\n")
      if result == p:
        break

proc select*(m: MultisteamSelect,
             conn: Connection,
             proto: string): Future[bool] {.async.} = 
  result = if proto.len > 0: 
            (await m.select(conn, @[proto])) == proto 
           else: 
            (await m.select(conn, @[])) == Codec

proc select*(m: MultisteamSelect, conn: Connection): Future[bool] = m.select(conn, "")

proc list*(m: MultisteamSelect,
           conn: Connection): Future[seq[string]] {.async.} =
  ## list remote protos requests on connection
  if not await m.select(conn):
    return

  await conn.write(m.ls) # send ls

  var list = newSeq[string]()
  let ms = cast[string](await conn.readLp())
  for s in ms.split("\n"):
    if s.len() > 0:
      list.add(s)

  result = list

proc handle*(m: MultisteamSelect, conn: Connection) {.async, gcsafe.} =
  while not conn.closed:
    block main:
      var ms = cast[string](await conn.readLp())
      ms.removeSuffix("\n")
      if ms.len() <= 0:
        await conn.write(m.na)

      if m.handlers.len() == 0:
        await conn.write(m.na)
        continue

      case ms:
        of "ls":
          var protos = ""
          for h in m.handlers:
            protos &= (h.proto & "\n")
          await conn.writeLp(protos)
        of Codec:
          await conn.write(m.codec)
        else:
          for h in m.handlers:
            if (not isNil(h.match) and h.match(ms)) or ms == h.proto:
              await conn.writeLp((h.proto & "\n"))
              try:
                await h.protocol.handler(conn, ms)
                break main
              except Exception as exc:
                echo exc.msg # TODO: Logging
          await conn.write(m.na)

proc addHandler*[T: LPProtocol](m: MultisteamSelect,
                                codec: string,
                                protocol: T,
                                matcher: Matcher = nil) =
  ## register a handler for the protocol
  m.handlers.add(HandlerHolder(proto: codec,
                               protocol: protocol,
                               match: matcher))
