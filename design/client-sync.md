# Client Server Syncrhonization

When connected a client wants to be up to date with all changes of state in the server
(that it can observe, e.g. excluding secret channels the user has no access to).

When a client disconnects, it will have been "up to date" up until the last event that
it received from the server.

A client keeps track of the following server-generated timestamps:

- Latest message received
- Latest user profile update observed
- Latest role update observed
- Latest user role update observed
- Latest channel update observed

And so forth for all resources the client is aware of.

On reconnection the client communicates these timestamps to the server, which then
the server will use to select all unseen changes to communicate to the client.

## Synchronizing Messages

When it comes to resources such as users, roles, and channels, clients must always
be updated fully. With regards to messages, there are a few different scenarios to be
aware of:

1. A lot of messages was sent while the client was disconnected.
2. Some messages have been edited while the client was disconnected.
3. Some messages have been deleted while the client was disconnected.

For each of these scenarios (and their combinations), care must be taken to ensure
correctness (client doesn't miss updates nor sees stale data) and efficiency (clients
don't store the full message history).

### Lots of messages (1)

Let's say that the default chat-history window for clients is 50 messages (meaning that
if the user wants to see older messages past 50, the client will have to send a request
to the server to obtain another window-size worth of old messages), then if lots of
messages have been sent while the client was disconnected, we only want to send the
latest 50 to the client.

What is important in this case, is to make sure tha the client is aware that the server
is "breaking continuity" from the message history the client has in cache.

### Message editing (2)

Editing a message should update its `last_edited` column in the server database.

Using this column will be then possible to select messages that have been updated
**after** the corresponding timestamp saved by the client.

That being said, care must be taken to ensure that we only send updates about modified
messages if they are still in the current chat-history window of the client, which
is independent of the `last_edited` timestamp value.

Consider this example:

```
  client
|------m-|--| (2 new messages)
       ^  ^^
```

In this example a client caches some messages and on reconnection there are two new
messages recorded by the server, and a recent message was edited (represented by `m`
in the graph).

In this case we do want the server to send to the client (represented by `^`in the graph):

- 2 new messages
- 1 modified message

Consider a different example:

```
  client
|------m-|------------------| (50+ new messages)
                        ^^^^
```

In this example many messages have been sent while the client was disconnected
and a (by now) older message was modified.

In this case we don't want to send to the client the modified message because
it has fallen off the active window.

Note that the message might have been edited **very recently** but that has no bearing
over whether it should be send to the client or not. What matters is the number
of newer messages.

### Deleted messages (3)

If a message is deleted, what described in (2) is not enought to guarantee that the
client doesn't show stale data.

To correctly and efficiently sync clients in the presence of message deletion, the
server must remember the timestamp when the latest message was deleted.

Consider this example:

```
  client
|------d-|--| (2 new messages)
       ^  ^^
```

In this example the deleted message was cached by the client and will remain inside
the active chat-history window after the update. In this case the server must recognize
that the `last_deleted_message` timestamp falls into the client chat-history window and
re-send the full updated window to the client, communicating that "continuity" was broken
(i.e the client must replace the full cache with the new data and not just merge it).

If the deleted message falls off the client chat-history window, then it will be
automatically flushed out by the client.

## Race conditions

When reconnecting and performing a host sync, the server will still process incoming
requests, which means that it will accept new messages, modify channels, etc.

Since the host sync task and other tasks are asynchronous, it's not possible to guarantee
perfect continuity between the `HostSync` message and subsequent events (e.g. a new message
might be part of the `HostSync` update and also be notified separately after).

To guarantee that the are no holes, the server will sign up a client connection **before**
starting to compute the `HostSync` message.

To ensure that duplicated events are recognized, the client must take care to validate the
`updated` field of an event in order to establish if the latest information was in
`HostSync` or not.

The initial sync is the only moment where this kind of confusion can happen (i.e. the
server will not send duplicated or stale notification out of order).
