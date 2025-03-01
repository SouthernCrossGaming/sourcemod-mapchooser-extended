/**
 * vim: set ts=4 :
 * =============================================================================
 * Rock The Vote Extended
 * Creates a map vote when the required number of players have requested one.
 *
 * Rock The Vote Extended (C)2012-2013 Powerlord (Ross Bemrose)
 * SourceMod (C)2004-2007 AlliedModders LLC.  All rights reserved.
 * =============================================================================
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * As a special exception, AlliedModders LLC gives you permission to link the
 * code of this program (as well as its derivative works) to "Half-Life 2," the
 * "Source Engine," the "SourcePawn JIT," and any Game MODs that run on software
 * by the Valve Corporation.  You must obey the GNU General Public License in
 * all respects for all other code used.  Additionally, AlliedModders LLC grants
 * this exception to all derivative works.  AlliedModders LLC defines further
 * exceptions, found in LICENSE.txt (as of this writing, version JULY-31-2007),
 * or <http://www.sourcemod.net/license.php>.
 *
 * Version: $Id$
 */

#include <sourcemod>
#include <mapchooser>
#include "include/mapchooser_extended"
#include <nextmap>
#include <morecolors>

#pragma semicolon 1

forward int OnMapVoteEnd(const String:map[]);

#define MCE_VERSION "1.10.0"
#define SQL_CONFIG "map_stats"
#define SQL_DBNAME "map_session"

public Plugin:myinfo =
{
	name = "Rock The Vote Extended",
	author = "Powerlord and AlliedModders LLC",
	description = "Provides RTV Map Voting",
	version = MCE_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=156974"
};

new Handle:g_Cvar_Needed = INVALID_HANDLE;
new Handle:g_Cvar_MinPlayers = INVALID_HANDLE;
new Handle:g_Cvar_InitialDelay = INVALID_HANDLE;
new Handle:g_Cvar_Interval = INVALID_HANDLE;
new Handle:g_Cvar_ChangeTime = INVALID_HANDLE;
new Handle:g_Cvar_RTVPostVoteAction = INVALID_HANDLE;
new Handle:g_Cvar_DisplayName = INVALID_HANDLE;
new Handle:g_hDB = INVALID_HANDLE;
new Handle:g_Cvar_ServerName = INVALID_HANDLE;
new Handle:g_Timer_ServerStatus = INVALID_HANDLE;

new bool:g_CanRTV = false;		// True if RTV loaded maps and is active.
new bool:g_RTVAllowed = false;	// True if RTV is available to players. Used to delay rtv votes.
new g_StartingPlayerCount = 0;
new g_SessionID = 0;
new g_PlayerCount = 0;
new g_Voters = 0;				// Total voters connected. Doesn't include fake clients.
new g_Votes = 0;				// Total number of "say rtv" votes
new g_TotalVotes = 0;			// Total votes that occurred
new g_VotesNeeded = 0;			// Necessary votes before map vote begins. (voters * percent_needed)
new bool:g_Voted[MAXPLAYERS+1] = {false, ...};
new bool:g_VoteSucceeded = false;
new g_MapTimeRemaining = 0;
new bool:g_ValidSession = false;
new g_MaxPlayerCount = 0;

new bool:g_InChange = false;

public OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("rockthevote.phrases");
	LoadTranslations("basevotes.phrases");

	g_Cvar_Needed = CreateConVar("sm_rtv_needed", "0.60", "Percentage of players needed to rockthevote (Def 60%)", 0, true, 0.05, true, 1.0);
	g_Cvar_MinPlayers = CreateConVar("sm_rtv_minplayers", "0", "Number of players required before RTV will be enabled.", 0, true, 0.0, true, float(MAXPLAYERS));
	g_Cvar_InitialDelay = CreateConVar("sm_rtv_initialdelay", "30.0", "Time (in seconds) before first RTV can be held", 0, true, 0.00);
	g_Cvar_Interval = CreateConVar("sm_rtv_interval", "240.0", "Time (in seconds) after a failed RTV before another can be held", 0, true, 0.00);
	g_Cvar_ChangeTime = CreateConVar("sm_rtv_changetime", "0", "When to change the map after a succesful RTV: 0 - Instant, 1 - RoundEnd, 2 - MapEnd", _, true, 0.0, true, 2.0);
	g_Cvar_RTVPostVoteAction = CreateConVar("sm_rtv_postvoteaction", "0", "What to do with RTV's after a mapvote has completed. 0 - Allow, success = instant change, 1 - Deny", _, true, 0.0, true, 1.0);
	g_Cvar_DisplayName = CreateConVar("sm_rtv_displayname", "1", "Display the Map's custom name, instead of the raw map name", _, true, 0.0, true, 1.0);

	RegConsoleCmd("say", Command_Say);
	RegConsoleCmd("say_team", Command_Say);

	RegConsoleCmd("sm_rtv", Command_RTV);

	RegAdminCmd("sm_forcertv", Command_ForceRTV, ADMFLAG_CHANGEMAP, "Force an RTV vote");
	RegAdminCmd("mce_forcertv", Command_ForceRTV, ADMFLAG_CHANGEMAP, "Force an RTV vote");

	// Rock The Vote Extended cvars
	CreateConVar("rtve_version", MCE_VERSION, "Rock The Vote Extended Version", FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_DONTRECORD);

	HookEvent("teamplay_point_captured", Event_Captured);
	HookEvent("teamplay_round_win", Event_RoundEnd);
	HookEvent("teamplay_round_start", Event_RoundStart);

	AutoExecConfig(true, "rtv");
	SQL_OpenConnection();
}

public OnAllPluginsLoaded()
{
	g_Cvar_ServerName = FindConVar("mce_server_name");
}

public OnMapStart()
{
	g_Voters = 0;
	g_Votes = 0;
	g_TotalVotes = 0;
	g_VotesNeeded = 0;
	g_MapTimeRemaining = 0;
	g_StartingPlayerCount = 0;
	g_PlayerCount = 0;
	g_MaxPlayerCount = 0;
	g_InChange = false;
	g_VoteSucceeded = false;
	g_ValidSession = false;

	/* Handle late load */
	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i))
		{
			OnClientConnected(i);
		}
	}

	CreateTimer(60.0, Timer_InitialServerStatus);
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_SessionID = GetTime();
	return Plugin_Continue;
}

public Action Event_Captured(Event event, const char[] name, bool dontBroadcast)
{
	char map[PLATFORM_MAX_PATH];
	char server[64];
	char capture_name[64];
	char query[4096];

	GetCurrentMap(map, PLATFORM_MAX_PATH);
	GetConVarString(g_Cvar_ServerName, server, sizeof(server));
	event.GetString("cpname", capture_name, sizeof(capture_name), "Unknown");
	
	int team = event.GetInt("team");
	int timeleft = GetTime() - g_SessionID;
	int player_count = GetRealClientCount(false);

	FormatEx(
		query,
		sizeof(query),
		"INSERT INTO map_stats (session_id, server_name, map_name, event_name, event_team, event_time, capture_name, players) VALUES(%i, \"%s\", \"%s\", \"point_capture\", %i, %i, \"%s\", %i)",
		g_SessionID, server, map, team, timeleft, capture_name, player_count);

	if (!SQL_TQuery(g_hDB, SQLErrorCheckCallback, query))
	{
		char error[255];
		SQL_GetError(g_hDB, error, sizeof(error));
		LogError("Failed to query (error: %s)", error);
	}

	return Plugin_Continue;
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	char map[PLATFORM_MAX_PATH];
	char server[64];
	char query[4096];

	GetCurrentMap(map, PLATFORM_MAX_PATH);
	GetConVarString(g_Cvar_ServerName, server, sizeof(server));
	
	float round_time = event.GetFloat("round_time");
	int full_round = event.GetInt("full_round");
	int team = event.GetInt("team");
	int timeleft = GetTime() - g_SessionID;
	int player_count = GetRealClientCount(false);

	FormatEx(
		query,
		sizeof(query),
		"INSERT INTO map_stats (session_id, server_name, map_name, event_name, event_team, event_time, total_time, full_round, players) VALUES(%i, \"%s\", \"%s\", \"round_end\", %i, %i, %f, %i, %i)",
		g_SessionID, server, map, team, timeleft, round_time, full_round, player_count);

	if (!SQL_TQuery(g_hDB, SQLErrorCheckCallback, query))
	{
		char error[255];
		SQL_GetError(g_hDB, error, sizeof(error));
		PrintToServer("Failed to query (error: %s)", error);
	}

	return Plugin_Continue;
}

public void T_InitDatabase(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl != INVALID_HANDLE)
    {
        g_hDB = hndl;
    }
    else
    {
        LogError("DATABASE FAILURE: %s", error);
    }
}

public void SQL_OpenConnection()
{
    if (SQL_CheckConfig(SQL_CONFIG))
    {
        SQL_TConnect(T_InitDatabase, SQL_CONFIG);
    }
    else
    {
        SetFailState("Unable to load cfg file (%s)", SQL_CONFIG);
    }
}

public OnMapEnd()
{
	KillTimerSafe(g_Timer_ServerStatus);

	g_CanRTV = false;
	g_RTVAllowed = false;

	// If the session was valid (ie. over a minute) and any players had connected, insert a record
	if (g_ValidSession && g_MaxPlayerCount > 0)
	{
		// Record the map session data to the DB
		char prefix[64];
		char map[PLATFORM_MAX_PATH];
		char server[64];
		char query[4096];

		GetCurrentMap(map, PLATFORM_MAX_PATH);
		GetCurrentMapPrefix(prefix, sizeof(prefix));
		GetConVarString(g_Cvar_ServerName, server, sizeof(server));

		FormatEx(
			query,
			sizeof(query),
			"INSERT INTO map_session (session_id, server_name, game_mode, map_name, starting_player_count, final_player_count, max_player_count, total_rtv_count, rtv_full, time_left) VALUES(%i, \"%s\", \"%s\", \"%s\", %i, %i, %i, %i, %b, %i)",
			GetTime(), server, prefix, map, g_StartingPlayerCount, g_PlayerCount, g_MaxPlayerCount, g_TotalVotes, g_VoteSucceeded, g_MapTimeRemaining);

		if (!SQL_TQuery(g_hDB, SQLErrorCheckCallback, query))
		{
			char error[255];
			SQL_GetError(g_hDB, error, sizeof(error));
			PrintToServer("Failed to query (error: %s)", error);
		}
	}
}

public OnConfigsExecuted()
{
	g_CanRTV = true;
	g_RTVAllowed = false;
	CreateTimer(GetConVarFloat(g_Cvar_InitialDelay), Timer_DelayRTV, _, TIMER_FLAG_NO_MAPCHANGE);
}

public OnClientConnected(client)
{
	if (IsFakeClient(client))
	{
		return;
	}

	g_Voted[client] = false;

	g_Voters++;
	g_VotesNeeded = RoundToFloor(float(g_Voters) * GetConVarFloat(g_Cvar_Needed));

	return;
}

public OnClientDisconnect(client)
{
	if (IsFakeClient(client))
	{
		return;
	}

	if (g_Voted[client])
	{
		g_Votes--;
	}

	g_Voters--;

	g_VotesNeeded = RoundToFloor(float(g_Voters) * GetConVarFloat(g_Cvar_Needed));

	if (!g_CanRTV)
	{
		return;
	}

	if (g_Votes &&
		g_Voters &&
		g_Votes >= g_VotesNeeded &&
		g_RTVAllowed)
	{
		if (GetConVarInt(g_Cvar_RTVPostVoteAction) == 1 && HasEndOfMapVoteFinished())
		{
			return;
		}

		StartRTV();
	}
}

public Action:Command_RTV(client, args)
{
	if (!g_CanRTV || !client)
	{
		return Plugin_Handled;
	}

	AttemptRTV(client);

	return Plugin_Handled;
}

public Action:Command_Say(client, args)
{
	if (!g_CanRTV || !client)
	{
		return Plugin_Continue;
	}

	decl String:text[192];
	if (!GetCmdArgString(text, sizeof(text)))
	{
		return Plugin_Continue;
	}

	new startidx = 0;
	if (text[strlen(text)-1] == '"')
	{
		text[strlen(text)-1] = '\0';
		startidx = 1;
	}

	new ReplySource:old = SetCmdReplySource(SM_REPLY_TO_CHAT);

	if (strcmp(text[startidx], "rtv", false) == 0 || strcmp(text[startidx], "rockthevote", false) == 0)
	{
		AttemptRTV(client);
	}

	SetCmdReplySource(old);

	return Plugin_Continue;
}

AttemptRTV(client)
{
	if (!g_RTVAllowed  || (GetConVarInt(g_Cvar_RTVPostVoteAction) == 1 && HasEndOfMapVoteFinished()))
	{
		CReplyToCommand(client, "[SM] %t", "RTV Not Allowed");
		return;
	}

	if (!CanMapChooserStartVote())
	{
		CReplyToCommand(client, "[SM] %t", "RTV Started");
		return;
	}

	if (GetClientCount(true) < GetConVarInt(g_Cvar_MinPlayers))
	{
		CReplyToCommand(client, "[SM] %t", "Minimal Players Not Met");
		return;
	}

	if (g_Voted[client])
	{
		CReplyToCommand(client, "[SM] %t", "Already Voted", g_Votes, g_VotesNeeded);
		return;
	}

	new String:name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));

	g_Votes++;
	g_TotalVotes++;
	g_Voted[client] = true;

	CPrintToChatAll("[SM] %t", "RTV Requested", name, g_Votes, g_VotesNeeded);

	if (g_Votes >= g_VotesNeeded)
	{
		StartRTV();
	}
}

public Action:Timer_DelayRTV(Handle:timer)
{
	g_RTVAllowed = true;
}

StartRTV()
{
	if (g_InChange)
	{
		return;
	}

	g_VoteSucceeded = true;

	if (EndOfMapVoteEnabled() && HasEndOfMapVoteFinished())
	{
		/* Change right now then */
		new String:map[PLATFORM_MAX_PATH];
		if (GetNextMap(map, sizeof(map)))
		{
			if (GetConVarBool(g_Cvar_DisplayName))
			{
				new String:mapName[PLATFORM_MAX_PATH];
				GetMapName(map, mapName, sizeof(mapName));
				CPrintToChatAll("[SM] %t", "Changing Maps", mapName);
			}
			else
			{
				CPrintToChatAll("[SM] %t", "Changing Maps", map);
			}

			CreateTimer(5.0, Timer_ChangeMap, _, TIMER_FLAG_NO_MAPCHANGE);
			g_InChange = true;

			ResetRTV();

			g_RTVAllowed = false;
		}
		return;
	}

	if (CanMapChooserStartVote())
	{
		new MapChange:when = MapChange:GetConVarInt(g_Cvar_ChangeTime);
		InitiateMapChooserVote(when);

		ResetRTV();

		g_RTVAllowed = false;
		CreateTimer(GetConVarFloat(g_Cvar_Interval), Timer_DelayRTV, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

ResetRTV()
{
	g_Votes = 0;

	for (new i=1; i<=MAXPLAYERS; i++)
	{
		g_Voted[i] = false;
	}
}

public Action:Timer_ChangeMap(Handle:hTimer)
{
	g_InChange = false;

	LogMessage("RTV changing map manually");

	new String:map[PLATFORM_MAX_PATH];
	if (GetNextMap(map, sizeof(map)))
	{
		ForceChangeLevel(map, "RTV after mapvote");
	}

	return Plugin_Stop;
}

// Rock The Vote Extended functions
public Action:Command_ForceRTV(client, args)
{
	if (!g_CanRTV || !client)
	{
		return Plugin_Handled;
	}

	ShowActivity2(client, "[RTVE] ", "%t", "Initiated Vote Map");

	StartRTV();

	return Plugin_Handled;
}

GetCurrentMapPrefix(String:buffer[], maxlen)
{
    decl String:currentMap[PLATFORM_MAX_PATH];
    GetCurrentMap(currentMap, sizeof(currentMap));

    GetMapPrefix(currentMap, buffer, maxlen);
}

stock GetMapPrefix(const String:map[], String:buffer[], maxlen)
{
    static Handle:re = INVALID_HANDLE;
    if (re == INVALID_HANDLE)
	{
		re = CompileRegex("^([a-zA-Z0-9]*)_(.*)$");
	}

    if (MatchRegex(re, map) > 1)
	{
        GetRegexSubString(re, 1, buffer, maxlen);
	}
    else
	{
        strcopy(buffer, maxlen, "");
	}
}

stock Action Timer_InitialServerStatus(Handle timer)
{
	g_Timer_ServerStatus = CreateTimer(2.0, Timer_ServerStatus, _, TIMER_REPEAT);
	g_StartingPlayerCount = GetRealClientCount(false);
	g_ValidSession = true;
}

stock Action Timer_ServerStatus(Handle timer)
{
	g_PlayerCount = GetRealClientCount(false);
	g_MaxPlayerCount = g_PlayerCount > g_MaxPlayerCount ? g_PlayerCount : g_MaxPlayerCount;

	int timeleft;
	GetMapTimeLeft(timeleft);
	g_MapTimeRemaining = timeleft;
}

GetRealClientCount(bool:inGameOnly = true)
{
	new clients = 0;
	for (new i = 1; i <= MaxClients; i++)
	{
		if (((inGameOnly) ? IsClientInGame(i) : IsClientConnected(i)) && !IsFakeClient(i))
		{
			clients++;
		}
	}

 	return clients;
}

stock void KillTimerSafe(Handle &hTimer)
{
    if (hTimer != INVALID_HANDLE)
    {
        KillTimer(hTimer);
        hTimer = INVALID_HANDLE;
    }
}

public void SQLErrorCheckCallback(Handle owner, Handle hndl, const char[] error, any data)
{
  if (strlen(error) > 1)
  {
    LogMessage("SQL Error: %s", error);
  }
}