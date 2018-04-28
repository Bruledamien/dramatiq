-- This file is a part of Dramatiq.
--
-- Copyright (C) 2017,2018 CLEARTYPE SRL <bogdan@cleartype.io>
--
-- Dramatiq is free software; you can redistribute it and/or modify it
-- under the terms of the GNU Lesser General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or (at
-- your option) any later version.
--
-- Dramatiq is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
-- FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public
-- License for more details.
--
-- You should have received a copy of the GNU Lesser General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

-- luacheck: globals ARGV KEYS redis unpack
-- dispatch(
--   args=[command, timestamp, queue_name, worker_id, heartbeat_timeout, dead_message_ttl, do_maintenance, ...],
--   keys=[namespace]
-- )

-- $namespace:__acks__.$worker_id.$queue_name
--   A set of message ids representing fetched-but-not-yet-acked
--   messages belonging to that (worker, queue) pair.
--
-- $namespace:__heartbeats__
--   A sorted set containing unique worker ids sorted by when their
--   last heartbeat was received.
--
-- $namespace:$queue_name
--   A list of message ids.
--
-- $namespace:$queue_name.msgs
--   A hash of message ids -> message data.
--
-- $namespace:$queue_name.XQ
--   A sorted set containing all the dead-lettered message ids
--   belonging to a queue, sorted by when they were dead lettered.
--
-- $namespace:$queue_name.XQ.msgs
--   A hash of message ids -> message data.

local namespace = KEYS[1]

local command = ARGV[1]
local timestamp = ARGV[2]
local queue_name = ARGV[3]
local worker_id = ARGV[4]
local heartbeat_timeout = ARGV[5]
local dead_message_ttl = ARGV[6]
local do_maintenance = ARGV[7]

local acks = namespace .. ":__acks__." .. worker_id
local heartbeats = namespace .. ":__heartbeats__"
redis.call("zadd", heartbeats, timestamp, worker_id)

local queue_acks = acks .. "." .. queue_name
local queue_full_name = namespace .. ":" .. queue_name
local queue_messages = queue_full_name .. ".msgs"
local xqueue_full_name = queue_full_name .. ".XQ"
local xqueue_messages = xqueue_full_name .. ".msgs"

-- Command-specific arguments.
local ARGS = {}
for i=8,#ARGV do
    ARGS[i - 7] = ARGV[i]
end

-- Every call to dispatch has some % chance to trigger maintenance on
-- a queue.  Maintenance moves any unacked messages belonging to dead
-- workers back to their queues and deletes any expired messages from
-- DLQs.
if do_maintenance == "1" then
    local dead_workers = redis.call("zrangebyscore", heartbeats, 0, timestamp - heartbeat_timeout)
    for i=1,#dead_workers do
        local dead_worker = dead_workers[i]
        local dead_worker_acks = namespace .. ":__acks__." .. dead_worker
        local dead_worker_queue_acks = dead_worker_acks .. "." .. queue_name
        local message_ids = redis.call("smembers", dead_worker_queue_acks)
        if next(message_ids) then
            redis.call("rpush", queue_full_name, unpack(message_ids))
            redis.call("del", dead_worker_queue_acks)
        end

        -- If there are no more ack groups for this worker, then
        -- remove it from the heartbeats set.
        local ack_queues = redis.call("keys", dead_worker_acks .. "*")
        if not next(ack_queues) then
            redis.call("zrem", heartbeats, dead_worker)
        end
    end

    local dead_message_ids = redis.call("zrangebyscore", xqueue_full_name, 0, timestamp - dead_message_ttl)
    if next(dead_message_ids) then
        redis.call("zrem", xqueue_full_name, unpack(dead_message_ids))
        redis.call("hdel", xqueue_messages, unpack(dead_message_ids))
    end

    -- The following code is required for backwards-compatibility with
    -- the old way acks used to be implemented.  It hoists any
    -- existing acks zsets into the per-worker sets.
    local compat_queue_acks = queue_full_name .. ".acks"
    local compat_message_ids = redis.call("zrangebyscore", compat_queue_acks, 0, timestamp - 86400000 * 7.5)
    if next(compat_message_ids) then
        redis.call("sadd", queue_acks, unpack(compat_message_ids))
        redis.call("zrem", compat_queue_acks, unpack(compat_message_ids))
    end
end


-- Enqueues a new message on $queue_full_name.
if command == "enqueue" then
    local message_id = ARGS[1]
    local message_data = ARGS[2]

    redis.call("hset", queue_messages, message_id, message_data)
    redis.call("rpush", queue_full_name, message_id)


-- Returns up to $prefetch number of messages from $queue_full_name.
elseif command == "fetch" then
    local prefetch = ARGS[1]

    local message_ids = {}
    for i=1,prefetch do
        local message_id = redis.call("lpop", queue_full_name)
        if not message_id then
            break
        end

        message_ids[i] = message_id
        redis.call("sadd", queue_acks, message_id)
    end

    if next(message_ids) ~= nil then
        return redis.call("hmget", queue_messages, unpack(message_ids))
    else
        return {}
    end


-- Moves fetched-but-not-processed messages back to their queues on
-- worker shutdown.
elseif command == "requeue" then
    for i=1,#ARGS do
        local message_id = ARGS[i]

        redis.call("srem", queue_acks, message_id)
        if redis.call("hexists", queue_messages, message_id) then
            redis.call("rpush", queue_full_name, message_id)
        end
    end


-- Acknowledges that a message has been processed.
elseif command == "ack" then
    local message_id = ARGS[1]

    redis.call("hdel", queue_messages, message_id)
    redis.call("srem", queue_acks, message_id)


-- Moves a message from a queue to a dead-letter queue.
elseif command == "nack" then
    local message_id = ARGS[1]

    -- unack the message
    redis.call("srem", queue_acks, message_id)

    -- then pop it off the messages hash and move it onto the DLQ
    local message = redis.call("hget", queue_messages, message_id)
    if message ~= nil then
        redis.call("zadd", xqueue_full_name, timestamp, message_id)
        redis.call("hset", xqueue_messages, message_id, message)
        redis.call("hdel", queue_messages, message_id)
    end


-- Removes all messages from a queue.
elseif command == "purge" then
    redis.call("del", queue_full_name, queue_acks, queue_messages, xqueue_full_name, xqueue_messages)


-- Used in tests to determine the size of the queue.
elseif command == "qsize" then
    return redis.call("hlen", queue_messages) + redis.call("scard", queue_acks)

end
