local LOGLEVEL = "debug"
local TIMEOUT = module:get_option_number("party_check_timeout", 60)

local is_admin = require "core.usermanager".is_admin
local is_healthcheck_room = module:require "util".is_healthcheck_room
local it = require "util.iterators"
local st = require "util.stanza"
local timer = require "util.timer"
module:log(LOGLEVEL, "loaded")

local function _is_admin(jid)
    return is_admin(jid, module.host)
end

module:hook("muc-occupant-pre-join", function (event)
    local room, stanza = event.room, event.stanza
    local user_jid = stanza.attr.from

    if is_healthcheck_room(room.jid) or _is_admin(user_jid) then
        module:log(LOGLEVEL, "location check, %s", user_jid)
        return
    end

    -- if an owner joins, start the party
    local context_user = event.origin.jitsi_meet_context_user
    if context_user then
        if context_user["affiliation"] == "owner" or
           context_user["affiliation"] == "moderator" or
           context_user["affiliation"] == "teacher" or
           context_user["moderator"] == "true" or
           context_user["moderator"] == true then
            module:log(LOGLEVEL, "let the party begin")
            return
        end
    end

    -- if the party has not started yet, don't accept the participant
    local occupant_count = it.count(room:each_occupant())
    if occupant_count < 2 then
        module:log(LOGLEVEL, "the party has not started yet")
        event.origin.send(st.error_reply(stanza, 'cancel', 'not-allowed'))
        return true
    end
end)

module:hook("muc-occupant-left", function (event)
    local room, occupant = event.room, event.occupant

    if is_healthcheck_room(room.jid) or _is_admin(occupant.jid) then
        return
    end

    -- no need to do anything for normal participant
    if room:get_affiliation(occupant.jid) ~= "owner" then
        module:log(LOGLEVEL, "a participant leaved, %s", occupant.jid)
        return
    end

    module:log(LOGLEVEL, "an owner leaved, %s", occupant.jid)

    -- check if there is any other owner here
    for _, o in room:each_occupant() do
        if not _is_admin(o.jid) then
            if room:get_affiliation(o.jid) == "owner" then
                module:log(LOGLEVEL, "an owner is still here, %s", o.jid)
                return
            end
        end
    end

    -- since there is no other owner, destroy the room after TIMEOUT secs
    timer.add_task(TIMEOUT, function()
        if is_healthcheck_room(room.jid) then
            return
        end

        local occupant_count = it.count(room:each_occupant())
        if occupant_count == 0 then
            return
        end

        -- last check before destroying the room
        -- if an owner is still here, cancel
        for _, o in room:each_occupant() do
            if not _is_admin(o.jid) then
                if room:get_affiliation(o.jid) == "owner" then
                    module:log(LOGLEVEL, "timer, an owner is here, %s", o.jid)
                    return
                end
            end
        end

        -- terminate the meeting
        room:set_persistent(false)
        room:destroy(nil, "The meeting has been terminated")
        module:log(LOGLEVEL, "the party finished")
    end)
end)
