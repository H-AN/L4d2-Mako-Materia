/*============================================================================================
	L4D2 Mako Materia
	----------------------------------------------------------------------------------------------
	Map:	l4d2_ffvii_makoreactor
	Desc:	Pure SourceMod enhancements for materias, the map / vscripts are left untouched.
			1. Optional through-wall glow on every materia (cvar).
			2. Casting moved from "+use on the orb" to "hold R" (progress bar, then the
			   map's own OnTimeUp output is fired, so all original logic / cooldowns run).
			3. The carrier sees a copy of the orb particle attached to his viewmodel;
			   the original orb is hidden only for him, everyone else still sees it.
			4. Hold a key (default Shift, or "bind g +mako_destroy") to destroy the carried
			   materia so another one can be picked up. Locked for N seconds after a cast.
----------------------------------------------------------------------------------------------*/
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION	"1.1.0"
#define MAP_NAME		"l4d2_ffvii_makoreactor"

#define MAT_COUNT		8
#define MAX_SLOTS		3		// Thunder has 3 charge particles, others 1

#define TEAM_SURVIVOR	2

#define KIND_NONE		0
#define KIND_SOURCE		1		// original orb particle (map entity)
#define KIND_COPY		2		// our viewmodel copy
#define KIND_GLOW		3		// our glow prop

// Index matches the value used by materia_assignation.nut (1..8) minus 1
static const char g_sMatName[MAT_COUNT][] = { "Fire", "Ice", "Heal", "Thunder", "Shield", "Haste", "Void", "Ultima" };
static const char g_sMatLabel[MAT_COUNT][] = { "火焰", "冰冻", "治疗", "雷电", "护盾", "加速", "虚空", "究极" };
// use_time / auto_disable taken from the map's func_button_timed entities
static const float g_fUseTime[MAT_COUNT] = { 1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 1.5, 2.0 };
static const bool g_bAutoDisable[MAT_COUNT] = { true, true, true, false, true, true, false, true };
static const int g_iGlowColor[MAT_COUNT][3] = {
	{ 255, 90, 0 },		// Fire
	{ 0, 200, 255 },	// Ice
	{ 0, 255, 200 },	// Heal
	{ 0, 0, 205 },		// Thunder
	{ 255, 230, 0 },	// Shield
	{ 255, 0, 200 },	// Haste
	{ 140, 0, 255 },	// Void
	{ 0, 255, 60 }		// Ultima
};
// Extra lateral / vertical offset of each slot on the viewmodel (Thunder charges 1..3)
static const float g_fSlotShift[MAX_SLOTS][2] = { { 0.0, 0.0 }, { 3.0, 2.0 }, { -3.0, 2.0 } };

ConVar g_cvEnable, g_cvGlow, g_cvGlowCarried, g_cvGlowModel, g_cvGlowRange, g_cvGlowScale,
	g_cvCastMode, g_cvCastButtons, g_cvVmCopy, g_cvVmOffset,
	g_cvDestroy, g_cvDestroyButtons, g_cvDestroyTime, g_cvDestroyLock;

bool g_bMapActive;
float g_fVmOffset[3];

int g_iSourceRef[MAT_COUNT][MAX_SLOTS];
int g_iButtonRef[MAT_COUNT];
int g_iGlowRef[MAT_COUNT];
int g_iGlowCarrier[MAT_COUNT];		// carrier userid the glow was built for (0 = on the ground)
int g_iCopyRef[MAT_COUNT][MAX_SLOTS];
int g_iCopyVm[MAT_COUNT];			// viewmodel ref the copies are parented to
int g_iCarrier[MAT_COUNT];			// userid, 0 = nobody

int g_iEntKind[2049];
int g_iEntMat[2049];
bool g_bHookedTransmit[2049];
bool g_bHookedUse[2049];

int g_iHoldMat[MAXPLAYERS + 1] = { -1, ... };
float g_fHoldStart[MAXPLAYERS + 1];
bool g_bNeedRelease[MAXPLAYERS + 1];
float g_fLockUntil[MAT_COUNT];
float g_fLastCast[MAT_COUNT];		// game time of the last cast (0 = never)
int g_iPollCount;

int g_iDestroyMat[MAXPLAYERS + 1] = { -1, ... };
float g_fDestroyStart[MAXPLAYERS + 1];
bool g_bDestroyNeedRelease[MAXPLAYERS + 1];
bool g_bDestroyCmd[MAXPLAYERS + 1];	// +mako_destroy held

public Plugin myinfo =
{
	name = "[L4D2] Mako Reactor Materia",
	author = "H-AN",
	description = "Materia glow, hold-R casting, viewmodel orb and destroy for l4d2_ffvii_makoreactor",
	version = PLUGIN_VERSION,
	url = ""
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2.");
		return APLRes_SilentFailure;
	}
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvEnable		= CreateConVar("mako_materia_enable", "1", "插件总开关", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvGlow		= CreateConVar("mako_materia_glow", "1", "全图魔石透视发光 (1=开启)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvGlowCarried	= CreateConVar("mako_materia_glow_carried", "0", "被拾取后是否继续对其他人发光 (0=拾取即删除发光)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvGlowModel	= CreateConVar("mako_materia_glow_model", "models/w_models/weapons/w_eq_painpills.mdl", "发光载体模型(透明, 只显示轮廓), 换图后生效");
	g_cvGlowRange	= CreateConVar("mako_materia_glow_range", "0", "发光可见距离 (0=无限制, 也可填很大的值如 100000)", FCVAR_NOTIFY, true, 0.0);
	g_cvGlowScale	= CreateConVar("mako_materia_glow_scale", "4.0", "发光载体模型缩放, 越大远处轮廓越明显", FCVAR_NOTIFY, true, 0.1, true, 20.0);
	g_cvCastMode	= CreateConVar("mako_materia_cast_mode", "1", "释放方式: 0=原版对着光球长按E, 1=长按指定按键(默认R), 屏蔽E", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvCastButtons	= CreateConVar("mako_materia_cast_buttons", "8192", "释放按键位掩码 (8192=IN_RELOAD, 可组合如 8192+4=蹲+R)");
	g_cvVmCopy		= CreateConVar("mako_materia_vm_orb", "1", "持有者视角模型上显示光球副本, 并对持有者隐藏原光球", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvVmOffset	= CreateConVar("mako_materia_vm_offset", "24 10 -8", "视角光球偏移: 前 右 上");
	g_cvDestroy		= CreateConVar("mako_materia_destroy", "1", "允许长按按键销毁身上的魔石", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDestroyButtons = CreateConVar("mako_materia_destroy_buttons", "131072", "销毁按键位掩码 (131072=Shift IN_SPEED, 0=只用 +mako_destroy 绑定), 始终可用 bind g +mako_destroy");
	g_cvDestroyTime	= CreateConVar("mako_materia_destroy_time", "2.0", "长按多少秒销毁", FCVAR_NOTIFY, true, 0.1, true, 10.0);
	g_cvDestroyLock	= CreateConVar("mako_materia_destroy_lock", "30", "释放魔石后多少秒内禁止销毁", FCVAR_NOTIFY, true, 0.0);
	CreateConVar("mako_materia_version", PLUGIN_VERSION, "Plugin version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	AutoExecConfig(true, "l4d2_mako_materia");

	g_cvVmOffset.AddChangeHook(OnVmOffsetChanged);
	g_cvVmCopy.AddChangeHook(OnVmOffsetChanged);
	g_cvGlowRange.AddChangeHook(OnGlowCvarChanged);
	g_cvGlowScale.AddChangeHook(OnGlowCvarChanged);
	g_cvGlowCarried.AddChangeHook(OnGlowCvarChanged);
	ParseVmOffset();

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEntityOutput("trigger_multiple", "OnStartTouch", OnTriggerTouch);
	HookEntityOutput("func_button_timed", "OnTimeUp", OnButtonTimeUp);

	RegConsoleCmd("+mako_destroy", Cmd_DestroyDown, "按住销毁身上的魔石 (bind g +mako_destroy)");
	RegConsoleCmd("-mako_destroy", Cmd_DestroyUp);
	RegAdminCmd("sm_mako_debug", Cmd_Debug, ADMFLAG_ROOT, "打印魔石状态");

	ResetState();
	CreateTimer(0.1, Timer_Poll, _, TIMER_REPEAT);
}

public void OnPluginEnd()
{
	for (int m = 0; m < MAT_COUNT; m++)
	{
		RemoveGlow(m);
		RemoveCopies(m);
	}
	for (int i = 1; i <= MaxClients; i++)
	{
		CancelHold(i);
		CancelDestroy(i);
	}
}

// ============================================================================================
// Map / round state
// ============================================================================================
public void OnMapStart()
{
	char map[64];
	GetCurrentMap(map, sizeof(map));
	g_bMapActive = StrEqual(map, MAP_NAME, false);
	ResetState();
	if (!g_bMapActive)
		return;

	char model[PLATFORM_MAX_PATH];
	g_cvGlowModel.GetString(model, sizeof(model));
	if (model[0])
		PrecacheModel(model, true);
	CreateTimer(1.0, Timer_Scan, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
	g_bMapActive = false;
	ResetState();
}

void ResetState()
{
	for (int m = 0; m < MAT_COUNT; m++)
	{
		for (int s = 0; s < MAX_SLOTS; s++)
		{
			g_iSourceRef[m][s] = INVALID_ENT_REFERENCE;
			g_iCopyRef[m][s] = INVALID_ENT_REFERENCE;
		}
		g_iButtonRef[m] = INVALID_ENT_REFERENCE;
		g_iGlowRef[m] = INVALID_ENT_REFERENCE;
		g_iGlowCarrier[m] = 0;
		g_iCopyVm[m] = INVALID_ENT_REFERENCE;
		g_iCarrier[m] = 0;
		g_fLockUntil[m] = 0.0;
		g_fLastCast[m] = 0.0;
	}
	for (int i = 1; i <= MaxClients; i++)
	{
		g_iHoldMat[i] = -1;
		g_bNeedRelease[i] = false;
		g_iDestroyMat[i] = -1;
		g_bDestroyNeedRelease[i] = false;
	}
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bMapActive)
		return;
	for (int m = 0; m < MAT_COUNT; m++)
	{
		RemoveGlow(m);
		RemoveCopies(m);
	}
	ResetState();
	CreateTimer(1.0, Timer_Scan, _, TIMER_FLAG_NO_MAPCHANGE);
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		CancelHold(i);
		CancelDestroy(i);
	}
}

public void OnClientDisconnect(int client)
{
	CancelHold(client);
	CancelDestroy(client);
	g_bNeedRelease[client] = false;
	g_bDestroyNeedRelease[client] = false;
	g_bDestroyCmd[client] = false;
}

public void OnEntityDestroyed(int entity)
{
	if (entity > 0 && entity < sizeof(g_iEntKind))
	{
		g_iEntKind[entity] = KIND_NONE;
		g_bHookedTransmit[entity] = false;
		g_bHookedUse[entity] = false;
	}
}

// ============================================================================================
// Entity discovery
// ============================================================================================
Action Timer_Scan(Handle timer)
{
	ScanEntities();
	return Plugin_Stop;
}

void ScanEntities()
{
	if (!g_bMapActive)
		return;

	char name[64], want[64];
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "info_particle_system")) != -1)
	{
		GetEntPropString(ent, Prop_Data, "m_iName", name, sizeof(name));
		if (strncmp(name, "M_", 2, false) != 0)
			continue;
		for (int m = 0; m < MAT_COUNT; m++)
		{
			for (int s = 0; s < MAX_SLOTS; s++)
			{
				if (!GetSourceName(m, s, want, sizeof(want)))
					continue;
				if (StrEqual(name, want, false))
					RegisterSource(ent, m, s);
			}
		}
	}

	ent = -1;
	while ((ent = FindEntityByClassname(ent, "func_button_timed")) != -1)
	{
		GetEntPropString(ent, Prop_Data, "m_iName", name, sizeof(name));
		for (int m = 0; m < MAT_COUNT; m++)
		{
			FormatEx(want, sizeof(want), "M_%s_Button", g_sMatName[m]);
			if (!StrEqual(name, want, false))
				continue;
			g_iButtonRef[m] = EntIndexToEntRef(ent);
			if (!g_bHookedUse[ent])
			{
				SDKHook(ent, SDKHook_Use, OnButtonUse);
				g_bHookedUse[ent] = true;
			}
		}
	}
}

bool GetSourceName(int m, int s, char[] buffer, int maxlen)
{
	if (m == 3)		// Thunder: charge particles
	{
		FormatEx(buffer, maxlen, "M_Thunder_Charge%d", s + 1);
		return true;
	}
	if (s != 0)
		return false;
	FormatEx(buffer, maxlen, "M_%s_Buttoneffect", g_sMatName[m]);
	return true;
}

void RegisterSource(int ent, int m, int s)
{
	g_iSourceRef[m][s] = EntIndexToEntRef(ent);
	g_iEntKind[ent] = KIND_SOURCE;
	g_iEntMat[ent] = m;
	if (!g_bHookedTransmit[ent])
	{
		SDKHook(ent, SDKHook_SetTransmit, OnSetTransmit);
		g_bHookedTransmit[ent] = true;
	}
}

// ============================================================================================
// Carrier detection
// ============================================================================================
void OnTriggerTouch(const char[] output, int caller, int activator, float delay)
{
	if (!g_bMapActive || activator < 1 || activator > MaxClients || !IsClientInGame(activator))
		return;

	char name[64], want[64];
	GetEntPropString(caller, Prop_Data, "m_iName", name, sizeof(name));
	for (int m = 0; m < MAT_COUNT; m++)
	{
		FormatEx(want, sizeof(want), "M_%s_Trigger", g_sMatName[m]);
		if (!StrEqual(name, want, false))
			continue;
		// materia_assignation.nut renames the player to "Carrier<Name>" at 0.01s then
		// "MateriaCarrier" at 0.26s, check in between
		DataPack dp;
		CreateDataTimer(0.12, Timer_CheckPickup, dp, TIMER_FLAG_NO_MAPCHANGE);
		dp.WriteCell(GetClientUserId(activator));
		dp.WriteCell(m);
		return;
	}
}

Action Timer_CheckPickup(Handle timer, DataPack dp)
{
	dp.Reset();
	int client = GetClientOfUserId(dp.ReadCell());
	int m = dp.ReadCell();
	if (client && IsClientInGame(client))
	{
		char name[64], want[64];
		GetEntPropString(client, Prop_Data, "m_iName", name, sizeof(name));
		FormatEx(want, sizeof(want), "Carrier%s", g_sMatName[m]);
		if (StrEqual(name, want, false))
			SetCarrier(m, client);
	}
	return Plugin_Stop;
}

// Fallback (late load / missed output): the parent script only exists after a pickup,
// its parent brush sits at EyePosition - 56 of the carrier.
void DetectCarriersByPosition()
{
	char want[64];
	for (int m = 0; m < MAT_COUNT; m++)
	{
		if (g_iCarrier[m])
			continue;
		FormatEx(want, sizeof(want), "M_%s_ParentScr", g_sMatName[m]);
		if (FindEntityByName("logic_script", want) == -1)
			continue;
		float anchor[3];
		if (!GetMateriaAnchor(m, anchor))
			continue;
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
				continue;
			float eye[3];
			GetClientEyePosition(i, eye);
			eye[2] -= 56.0;
			if (GetVectorDistance(eye, anchor) < 64.0)
			{
				SetCarrier(m, i);
				break;
			}
		}
	}
}

void SetCarrier(int m, int client)
{
	int userid = GetClientUserId(client);
	if (g_iCarrier[m] == userid)
		return;
	RemoveCopies(m);
	RemoveGlow(m);		// drop the ground glow right away, rebuilt for the carrier if wanted
	g_iCarrier[m] = userid;
	if (IsFakeClient(client) || !g_cvEnable.BoolValue)
		return;
	if (g_cvCastMode.IntValue == 1)
	{
		char key[32];
		GetCastKeyLabel(key, sizeof(key));
		PrintToChat(client, "\x04[魔石]\x01 你拾取了 \x05%s\x01 魔石, 长按 \x04%s\x01 释放", g_sMatLabel[m], key);
	}
	if (g_cvDestroy.BoolValue)
	{
		char key[32];
		GetDestroyKeyLabel(key, sizeof(key));
		PrintToChat(client, "\x04[魔石]\x01 长按 \x04%s\x01 销毁当前魔石 (也可控制台 \x05bind g +mako_destroy\x01)", key);
	}
}

void ClearCarrier(int m)
{
	int client = GetClientOfUserId(g_iCarrier[m]);
	g_iCarrier[m] = 0;
	RemoveCopies(m);
	if (client && g_iHoldMat[client] == m)
		CancelHold(client);
}

// ============================================================================================
// Poll: glow / viewmodel copy / carrier validation
// ============================================================================================
Action Timer_Poll(Handle timer)
{
	if (!g_bMapActive)
		return Plugin_Continue;

	g_iPollCount++;
	if (g_iPollCount % 10 == 0)
	{
		if (!HasAnySource())
			ScanEntities();
		DetectCarriersByPosition();
	}

	for (int m = 0; m < MAT_COUNT; m++)
	{
		ValidateCarrier(m);
		UpdateGlow(m);
		UpdateCopies(m);
		UpdateSourceTransmit(m);
	}
	return Plugin_Continue;
}

bool HasAnySource()
{
	for (int m = 0; m < MAT_COUNT; m++)
		for (int s = 0; s < MAX_SLOTS; s++)
			if (RefToIndex(g_iSourceRef[m][s]) != -1)
				return true;
	return false;
}

void ValidateCarrier(int m)
{
	if (!g_iCarrier[m])
		return;
	int client = GetClientOfUserId(g_iCarrier[m]);
	if (!client || !IsClientInGame(client))
	{
		ClearCarrier(m);
		return;
	}
	// Ultima kills its button + orb after casting, but the parent script keeps following the
	// player and the name stays "MateriaCarrier": keep him as carrier so he can destroy it.
	if (RefToIndex(g_iButtonRef[m]) == -1 && !HasSource(m) && FindParentScript(m) == -1)
		ClearCarrier(m);
}

int FindParentScript(int m)
{
	char name[64];
	FormatEx(name, sizeof(name), "M_%s_ParentScr", g_sMatName[m]);
	return FindEntityByName("logic_script", name);
}

bool HasSource(int m)
{
	for (int s = 0; s < MAX_SLOTS; s++)
		if (RefToIndex(g_iSourceRef[m][s]) != -1)
			return true;
	return false;
}

// Carrier alive on survivor team (dead carriers get their orb parked at 0 0 0 by the map)
int GetActiveCarrier(int m)
{
	int client = GetClientOfUserId(g_iCarrier[m]);
	if (client && IsClientInGame(client) && GetClientTeam(client) == TEAM_SURVIVOR && IsPlayerAlive(client))
		return client;
	return 0;
}

// ---------------- Glow ----------------
void UpdateGlow(int m)
{
	float anchor[3];
	bool want = g_cvEnable.BoolValue && g_cvGlow.BoolValue && GetMateriaAnchor(m, anchor);
	bool carried = g_iCarrier[m] != 0;
	if (want && carried && (!g_cvGlowCarried.BoolValue || !GetActiveCarrier(m)))
		want = false;

	int glow = RefToIndex(g_iGlowRef[m]);
	// Carrier changed (pickup / handover): never reuse the entity, otherwise the client
	// that stops receiving it keeps a dormant ghost outline at the last position.
	if (glow != -1 && g_iGlowCarrier[m] != g_iCarrier[m])
	{
		RemoveGlow(m);
		glow = -1;
	}
	if (!want)
	{
		if (glow != -1)
			RemoveGlow(m);
		return;
	}
	if (glow == -1)
	{
		glow = CreateGlow(m, anchor);
		if (glow == -1)
			return;
		g_iGlowCarrier[m] = g_iCarrier[m];
	}

	// Not parented on purpose: FL_EDICT_ALWAYS entities can be sent without their parent,
	// so we move it ourselves to keep the outline visible map-wide.
	float pos[3];
	GetEntPropVector(glow, Prop_Data, "m_vecAbsOrigin", pos);
	if (GetVectorDistance(pos, anchor) > 1.0)
		TeleportEntity(glow, anchor, NULL_VECTOR, NULL_VECTOR);

	// On the ground: always networked to everyone, no PVS / distance culling.
	// Carried: go through SetTransmit so the carrier himself doesn't receive it.
	int flags = GetEdictFlags(glow);
	if (carried)
		flags &= ~FL_EDICT_ALWAYS;
	else
		flags |= FL_EDICT_ALWAYS;
	SetEdictFlags(glow, flags);
}

int CreateGlow(int m, const float pos[3])
{
	char model[PLATFORM_MAX_PATH];
	g_cvGlowModel.GetString(model, sizeof(model));
	if (!model[0] || !IsModelPrecached(model))
		return -1;

	int ent = CreateEntityByName("prop_dynamic_override");
	if (ent == -1)
		return -1;

	char name[32];
	FormatEx(name, sizeof(name), "mako_glow_%s", g_sMatName[m]);	// must not start with "M_" (map kills M_*)
	DispatchKeyValue(ent, "targetname", name);
	DispatchKeyValue(ent, "model", model);
	DispatchKeyValue(ent, "solid", "0");
	DispatchKeyValue(ent, "disableshadows", "1");
	DispatchKeyValue(ent, "disablereceiveshadows", "1");
	DispatchKeyValue(ent, "rendermode", "10");		// kRenderNone for the model, outline still drawn
	DispatchKeyValue(ent, "fademindist", "-1");
	DispatchKeyValue(ent, "fademaxdist", "0");
	DispatchKeyValueFloat(ent, "modelscale", g_cvGlowScale.FloatValue);
	DispatchKeyValueVector(ent, "origin", pos);
	if (!DispatchSpawn(ent))
	{
		RemoveEntity(ent);
		return -1;
	}
	SetEntityRenderMode(ent, RENDER_TRANSCOLOR);
	SetEntityRenderColor(ent, 255, 255, 255, 0);
	SetEntProp(ent, Prop_Send, "m_CollisionGroup", 0);
	if (HasEntProp(ent, Prop_Send, "m_flModelScale"))
		SetEntPropFloat(ent, Prop_Send, "m_flModelScale", g_cvGlowScale.FloatValue);

	SetEntProp(ent, Prop_Send, "m_iGlowType", 3);
	SetEntProp(ent, Prop_Send, "m_nGlowRange", g_cvGlowRange.IntValue);
	SetEntProp(ent, Prop_Send, "m_nGlowRangeMin", 0);
	SetEntProp(ent, Prop_Send, "m_glowColorOverride",
		g_iGlowColor[m][0] + (g_iGlowColor[m][1] << 8) + (g_iGlowColor[m][2] << 16));

	g_iEntKind[ent] = KIND_GLOW;
	g_iEntMat[ent] = m;
	// Only needed while carried (to hide from the carrier); on the ground it's FL_EDICT_ALWAYS
	if (g_iCarrier[m])
	{
		SDKHook(ent, SDKHook_SetTransmit, OnSetTransmit);
		g_bHookedTransmit[ent] = true;
	}
	SetEdictFlags(ent, GetEdictFlags(ent) | FL_EDICT_ALWAYS);
	g_iGlowRef[m] = EntIndexToEntRef(ent);
	return ent;
}

void RemoveGlow(int m)
{
	KillRef(g_iGlowRef[m]);
	g_iGlowCarrier[m] = 0;
}

// World position of the orb: computed from the parent brush, since abs origins of
// parented entities can be stale on the server.
bool GetMateriaAnchor(int m, float out[3])
{
	int src = -1;
	for (int s = 0; s < MAX_SLOTS && src == -1; s++)
		src = RefToIndex(g_iSourceRef[m][s]);
	if (src == -1)
		return false;

	float local[3];
	GetEntPropVector(src, Prop_Data, "m_vecOrigin", local);
	int parent = GetEntPropEnt(src, Prop_Data, "m_hMoveParent");
	if (parent == -1)
	{
		out = local;
		return true;
	}

	float porg[3], pang[3], fwd[3], right[3], up[3];
	GetEntPropVector(parent, Prop_Data, "m_vecOrigin", porg);
	GetEntPropVector(parent, Prop_Data, "m_angRotation", pang);
	GetAngleVectors(pang, fwd, right, up);
	// Local space: x = forward, y = left, z = up
	for (int i = 0; i < 3; i++)
		out[i] = porg[i] + fwd[i] * local[0] - right[i] * local[1] + up[i] * local[2];

	// Dead carrier: map parks the orb at 0 0 0
	return !(porg[0] == 0.0 && porg[1] == 0.0 && porg[2] == 0.0);
}

// ---------------- Viewmodel copy ----------------
void UpdateCopies(int m)
{
	int client = GetActiveCarrier(m);
	if (!client || !g_cvEnable.BoolValue || !g_cvVmCopy.BoolValue || IsFakeClient(client))
	{
		RemoveCopies(m);
		return;
	}

	int vm = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
	if (vm == -1 || !IsValidEntity(vm))
	{
		RemoveCopies(m);
		return;
	}
	int vmRef = EntIndexToEntRef(vm);
	if (g_iCopyVm[m] != vmRef)
	{
		RemoveCopies(m);
		g_iCopyVm[m] = vmRef;
	}

	for (int s = 0; s < MAX_SLOTS; s++)
	{
		int src = RefToIndex(g_iSourceRef[m][s]);
		int copy = RefToIndex(g_iCopyRef[m][s]);
		if (src == -1)
		{
			if (copy != -1)
				KillRef(g_iCopyRef[m][s]);
			continue;
		}
		if (copy == -1)
		{
			copy = CreateCopy(m, s, client, vm, src);
			if (copy == -1)
				continue;
		}

		// Mirror Start/Stop of the original (cooldown / thunder charges)
		bool srcActive = GetEntProp(src, Prop_Send, "m_bActive") != 0;
		bool copyActive = GetEntProp(copy, Prop_Send, "m_bActive") != 0;
		if (srcActive != copyActive)
			AcceptEntityInput(copy, srcActive ? "Start" : "Stop");

		SetEdictFlags(copy, GetEdictFlags(copy) & ~FL_EDICT_ALWAYS);
	}
}

int CreateCopy(int m, int s, int client, int vm, int src)
{
	char effect[64];
	GetEntPropString(src, Prop_Data, "m_iszEffectName", effect, sizeof(effect));
	if (!effect[0])
		return -1;

	int ent = CreateEntityByName("info_particle_system");
	if (ent == -1)
		return -1;

	char name[32];
	FormatEx(name, sizeof(name), "mako_vmorb_%s_%d", g_sMatName[m], s);
	DispatchKeyValue(ent, "targetname", name);
	DispatchKeyValue(ent, "effect_name", effect);
	DispatchKeyValue(ent, "start_active", "0");

	// Place it in front of the eyes first so the server side position is sane, then parent
	float eye[3], ang[3], fwd[3], right[3], up[3], pos[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	GetAngleVectors(ang, fwd, right, up);
	float f = g_fVmOffset[0];
	float r = g_fVmOffset[1] + g_fSlotShift[s][0];
	float u = g_fVmOffset[2] + g_fSlotShift[s][1];
	for (int i = 0; i < 3; i++)
		pos[i] = eye[i] + fwd[i] * f + right[i] * r + up[i] * u;
	DispatchKeyValueVector(ent, "origin", pos);
	DispatchSpawn(ent);
	ActivateEntity(ent);

	SetVariantString("!activator");
	AcceptEntityInput(ent, "SetParent", vm);

	// Local offset relative to the viewmodel (x = forward, y = left, z = up)
	float local[3];
	local[0] = f;
	local[1] = -r;
	local[2] = u;
	SetEntPropVector(ent, Prop_Send, "m_vecOrigin", local);
	float zero[3];
	SetEntPropVector(ent, Prop_Send, "m_angRotation", zero);

	g_iEntKind[ent] = KIND_COPY;
	g_iEntMat[ent] = m;
	SDKHook(ent, SDKHook_SetTransmit, OnSetTransmit);
	g_bHookedTransmit[ent] = true;
	SetEdictFlags(ent, GetEdictFlags(ent) & ~FL_EDICT_ALWAYS);

	if (GetEntProp(src, Prop_Send, "m_bActive"))
		AcceptEntityInput(ent, "Start");

	g_iCopyRef[m][s] = EntIndexToEntRef(ent);
	return ent;
}

void RemoveCopies(int m)
{
	for (int s = 0; s < MAX_SLOTS; s++)
		KillRef(g_iCopyRef[m][s]);
	g_iCopyVm[m] = INVALID_ENT_REFERENCE;
}

// While the carrier has a viewmodel copy, the original must go through SetTransmit
void UpdateSourceTransmit(int m)
{
	if (!ShouldHideSourceFor(m, GetActiveCarrier(m)))
		return;
	for (int s = 0; s < MAX_SLOTS; s++)
	{
		int src = RefToIndex(g_iSourceRef[m][s]);
		if (src != -1)
			SetEdictFlags(src, GetEdictFlags(src) & ~FL_EDICT_ALWAYS);
	}
}

bool ShouldHideSourceFor(int m, int client)
{
	if (!client || !g_cvEnable.BoolValue || !g_cvVmCopy.BoolValue)
		return false;
	if (GetClientOfUserId(g_iCarrier[m]) != client)
		return false;
	for (int s = 0; s < MAX_SLOTS; s++)
		if (RefToIndex(g_iCopyRef[m][s]) != -1)
			return true;
	return false;
}

Action OnSetTransmit(int entity, int client)
{
	if (entity <= 0 || entity >= sizeof(g_iEntKind))
		return Plugin_Continue;

	int m = g_iEntMat[entity];
	switch (g_iEntKind[entity])
	{
		case KIND_SOURCE:
		{
			if (GetEdictFlags(entity) & FL_EDICT_ALWAYS)
				SetEdictFlags(entity, GetEdictFlags(entity) & ~FL_EDICT_ALWAYS);
			if (ShouldHideSourceFor(m, client))
				return Plugin_Handled;
		}
		case KIND_COPY:
		{
			if (GetEdictFlags(entity) & FL_EDICT_ALWAYS)
				SetEdictFlags(entity, GetEdictFlags(entity) & ~FL_EDICT_ALWAYS);
			if (GetClientOfUserId(g_iCarrier[m]) != client)
				return Plugin_Handled;
		}
		case KIND_GLOW:
		{
			if (g_iCarrier[m] && GetClientOfUserId(g_iCarrier[m]) == client)
				return Plugin_Handled;
		}
	}
	return Plugin_Continue;
}

// ============================================================================================
// Casting: hold R instead of +use on the orb
// ============================================================================================
Action OnButtonUse(int entity, int activator, int caller, UseType type, float value)
{
	if (g_bMapActive && g_cvEnable.BoolValue && g_cvCastMode.IntValue == 1)
		return Plugin_Handled;
	return Plugin_Continue;
}

public void OnPlayerRunCmdPost(int client, int buttons)
{
	if (!g_bMapActive || !g_cvEnable.BoolValue || IsFakeClient(client))
		return;

	// Destroy has priority: while its key is held by a carrier, casting is suspended
	if (HandleDestroy(client, buttons))
	{
		if (g_iHoldMat[client] != -1)
			CancelHold(client);
		g_bNeedRelease[client] = true;
		return;
	}

	if (g_cvCastMode.IntValue != 1)
		return;

	int mask = g_cvCastButtons.IntValue;
	bool held = mask != 0 && (buttons & mask) == mask;
	if (!held)
	{
		if (g_iHoldMat[client] != -1)
			CancelHold(client);
		g_bNeedRelease[client] = false;
		return;
	}
	if (g_bNeedRelease[client])
		return;

	int m = g_iHoldMat[client];
	if (m == -1)
	{
		m = FindCastable(client);
		if (m == -1)
		{
			// Holding R with nothing ready: plain reload, don't start later mid-hold
			g_bNeedRelease[client] = true;
			return;
		}
		StartHold(client, m);
		return;
	}

	if (!CanCast(client, m))
	{
		CancelHold(client);
		g_bNeedRelease[client] = true;
		return;
	}
	if (GetGameTime() - g_fHoldStart[client] >= g_fUseTime[m])
	{
		CancelHold(client);
		CastMateria(client, m);
		g_bNeedRelease[client] = true;
	}
}

int FindCastable(int client)
{
	for (int m = 0; m < MAT_COUNT; m++)
		if (CanCast(client, m))
			return m;
	return -1;
}

bool CanCast(int client, int m)
{
	if (GetClientOfUserId(g_iCarrier[m]) != client)
		return false;
	if (GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client) || IsPinnedOrIncapped(client))
		return false;
	if (RefToIndex(g_iButtonRef[m]) == -1 || GetGameTime() < g_fLockUntil[m])
		return false;
	return IsMateriaReady(m);
}

// The map starts/stops the orb particle exactly when the button is enabled/disabled
// (Thunder: any charge particle active = has charges)
bool IsMateriaReady(int m)
{
	for (int s = 0; s < MAX_SLOTS; s++)
	{
		int src = RefToIndex(g_iSourceRef[m][s]);
		if (src != -1 && GetEntProp(src, Prop_Send, "m_bActive"))
			return true;
	}
	return false;
}

bool IsPinnedOrIncapped(int client)
{
	if (GetEntProp(client, Prop_Send, "m_isIncapacitated") || GetEntProp(client, Prop_Send, "m_isHangingFromLedge"))
		return true;
	static const char attackers[][] = { "m_pounceAttacker", "m_tongueOwner", "m_pummelAttacker", "m_carryAttacker", "m_jockeyAttacker" };
	for (int i = 0; i < sizeof(attackers); i++)
		if (GetEntPropEnt(client, Prop_Send, attackers[i]) > 0)
			return true;
	return false;
}

void StartHold(int client, int m)
{
	g_iHoldMat[client] = m;
	g_fHoldStart[client] = GetGameTime();
	SetEntPropFloat(client, Prop_Send, "m_flProgressBarStartTime", g_fHoldStart[client]);
	SetEntPropFloat(client, Prop_Send, "m_flProgressBarDuration", g_fUseTime[m]);
	PrintCenterText(client, "正在释放 %s 魔石...", g_sMatLabel[m]);
}

void CancelHold(int client)
{
	if (client < 1 || client > MaxClients || g_iHoldMat[client] == -1)
		return;
	g_iHoldMat[client] = -1;
	if (IsClientInGame(client) && GetEntPropFloat(client, Prop_Send, "m_flProgressBarStartTime") == g_fHoldStart[client])
	{
		SetEntPropFloat(client, Prop_Send, "m_flProgressBarStartTime", 0.0);
		SetEntPropFloat(client, Prop_Send, "m_flProgressBarDuration", 0.0);
	}
}

void CastMateria(int client, int m)
{
	int button = RefToIndex(g_iButtonRef[m]);
	if (button == -1)
		return;
	// Same as the timed button completing: all original map logic runs from here
	MarkCast(m);
	FireEntityOutput(button, "OnTimeUp", client);
	if (g_bAutoDisable[m])
		AcceptEntityInput(button, "Disable");
	// Orb Stop input goes through the I/O queue, block re-cast until it is processed
	g_fLockUntil[m] = GetGameTime() + 1.0;
}

// Original +use cast (cast_mode 0) or any other OnTimeUp source
void OnButtonTimeUp(const char[] output, int caller, int activator, float delay)
{
	if (!g_bMapActive)
		return;
	for (int m = 0; m < MAT_COUNT; m++)
	{
		if (RefToIndex(g_iButtonRef[m]) == caller)
		{
			MarkCast(m);
			return;
		}
	}
}

void MarkCast(int m)
{
	float now = GetGameTime();
	if (now - g_fLastCast[m] < 0.5)		// CastMateria + output hook in the same tick
		return;
	g_fLastCast[m] = now;

	int client = GetClientOfUserId(g_iCarrier[m]);
	if (m == 7 && client && IsClientInGame(client) && !IsFakeClient(client) && g_cvDestroy.BoolValue)
	{
		char key[32];
		GetDestroyKeyLabel(key, sizeof(key));
		PrintToChat(client, "\x04[魔石]\x01 究极魔石已用尽, \x04%d\x01 秒后可长按 \x04%s\x01 销毁以拾取其他魔石",
			g_cvDestroyLock.IntValue, key);
	}
}

// ============================================================================================
// Destroy: hold a key to remove the carried materia, so another one can be picked up
// ============================================================================================
Action Cmd_DestroyDown(int client, int args)
{
	if (client > 0 && client <= MaxClients)
		g_bDestroyCmd[client] = true;
	return Plugin_Handled;
}

Action Cmd_DestroyUp(int client, int args)
{
	if (client > 0 && client <= MaxClients)
		g_bDestroyCmd[client] = false;
	return Plugin_Handled;
}

// Returns true when the destroy key is held by a carrier (input consumed, no casting)
bool HandleDestroy(int client, int buttons)
{
	int mask = g_cvDestroyButtons.IntValue;
	bool held = g_bDestroyCmd[client] || (mask != 0 && (buttons & mask) == mask);
	if (!held || !g_cvDestroy.BoolValue)
	{
		CancelDestroy(client);
		g_bDestroyNeedRelease[client] = false;
		return false;
	}

	int m = FindCarried(client);
	if (m == -1)
	{
		CancelDestroy(client);
		return false;
	}
	if (g_bDestroyNeedRelease[client])
		return true;

	if (!CanDestroy(client))
	{
		CancelDestroy(client);
		g_bDestroyNeedRelease[client] = true;
		return true;
	}

	float remain = g_fLastCast[m] + g_cvDestroyLock.FloatValue - GetGameTime();
	if (g_fLastCast[m] > 0.0 && remain > 0.0)
	{
		CancelDestroy(client);
		PrintCenterText(client, "%s 魔石刚刚释放过, %d 秒后才能销毁", g_sMatLabel[m], RoundToCeil(remain));
		g_bDestroyNeedRelease[client] = true;
		return true;
	}

	if (g_iDestroyMat[client] != m)
	{
		CancelDestroy(client);
		StartDestroy(client, m);
		return true;
	}

	if (GetGameTime() - g_fDestroyStart[client] >= g_cvDestroyTime.FloatValue)
	{
		CancelDestroy(client);
		DestroyMateria(client, m);
		g_bDestroyNeedRelease[client] = true;
	}
	return true;
}

int FindCarried(int client)
{
	int userid = GetClientUserId(client);
	for (int m = 0; m < MAT_COUNT; m++)
		if (g_iCarrier[m] == userid)
			return m;
	return -1;
}

bool CanDestroy(int client)
{
	return GetClientTeam(client) == TEAM_SURVIVOR && IsPlayerAlive(client) && !IsPinnedOrIncapped(client);
}

void StartDestroy(int client, int m)
{
	g_iDestroyMat[client] = m;
	g_fDestroyStart[client] = GetGameTime();
	SetEntPropFloat(client, Prop_Send, "m_flProgressBarStartTime", g_fDestroyStart[client]);
	SetEntPropFloat(client, Prop_Send, "m_flProgressBarDuration", g_cvDestroyTime.FloatValue);
	PrintCenterText(client, "正在销毁 %s 魔石... 松开取消", g_sMatLabel[m]);
}

void CancelDestroy(int client)
{
	if (client < 1 || client > MaxClients || g_iDestroyMat[client] == -1)
		return;
	g_iDestroyMat[client] = -1;
	if (IsClientInGame(client) && GetEntPropFloat(client, Prop_Send, "m_flProgressBarStartTime") == g_fDestroyStart[client])
	{
		SetEntPropFloat(client, Prop_Send, "m_flProgressBarStartTime", 0.0);
		SetEntPropFloat(client, Prop_Send, "m_flProgressBarDuration", 0.0);
	}
}

void DestroyMateria(int client, int m)
{
	char name[64];

	// 1. Stop the follow script (it would otherwise keep moving / re-killing children)
	int scr = FindParentScript(m);

	// 2. Parent brush: resolve through a child first, the map renames parents on the fly
	int parent = -1;
	for (int s = 0; s < MAX_SLOTS && parent == -1; s++)
	{
		int src = RefToIndex(g_iSourceRef[m][s]);
		if (src != -1)
			parent = GetEntPropEnt(src, Prop_Data, "m_hMoveParent");
	}
	if (parent == -1)
	{
		int button = RefToIndex(g_iButtonRef[m]);
		if (button != -1)
			parent = GetEntPropEnt(button, Prop_Data, "m_hMoveParent");
	}
	if (parent == -1)
	{
		FormatEx(name, sizeof(name), "M_%s_Parent", g_sMatName[m]);
		parent = FindEntityByName("func_movelinear", name);
	}

	if (scr != -1)
		AcceptEntityInput(scr, "Kill");
	// KillHierarchy: button, orb particles, trigger_hurt etc. are all parented to it
	if (parent != -1)
		AcceptEntityInput(parent, "KillHierarchy");

	// 3. Release the player exactly like the map expects a free survivor to be
	SetVariantString("PretendMateria <- null; HasMateria <- false");
	AcceptEntityInput(client, "RunScriptCode");
	DispatchKeyValue(client, "targetname", "SurvivorHuman");

	// 4. Plugin side
	RemoveCopies(m);
	RemoveGlow(m);
	g_iCarrier[m] = 0;
	for (int s = 0; s < MAX_SLOTS; s++)
		g_iSourceRef[m][s] = INVALID_ENT_REFERENCE;
	g_iButtonRef[m] = INVALID_ENT_REFERENCE;

	char pname[MAX_NAME_LENGTH];
	GetClientName(client, pname, sizeof(pname));
	PrintToChatAll("\x04[魔石]\x01 \x03%s\x01 销毁了 \x05%s\x01 魔石", pname, g_sMatLabel[m]);
	PrintCenterText(client, "已销毁 %s 魔石, 现在可以拾取其他魔石", g_sMatLabel[m]);
}

// ============================================================================================
// Helpers
// ============================================================================================
int RefToIndex(int ref)
{
	if (ref == INVALID_ENT_REFERENCE || ref == 0)
		return -1;
	int ent = EntRefToEntIndex(ref);
	return (ent == INVALID_ENT_REFERENCE) ? -1 : ent;
}

void KillRef(int &ref)
{
	int ent = RefToIndex(ref);
	if (ent != -1)
		RemoveEntity(ent);
	ref = INVALID_ENT_REFERENCE;
}

int FindEntityByName(const char[] classname, const char[] targetname)
{
	char name[64];
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, classname)) != -1)
	{
		GetEntPropString(ent, Prop_Data, "m_iName", name, sizeof(name));
		if (StrEqual(name, targetname, false))
			return ent;
	}
	return -1;
}

void GetCastKeyLabel(char[] buffer, int maxlen)
{
	strcopy(buffer, maxlen, g_cvCastButtons.IntValue == IN_RELOAD ? "R" : "释放键");
}

void GetDestroyKeyLabel(char[] buffer, int maxlen)
{
	switch (g_cvDestroyButtons.IntValue)
	{
		case 0:						strcopy(buffer, maxlen, "+mako_destroy 绑定键");
		case IN_SPEED:				strcopy(buffer, maxlen, "Shift");
		case IN_ZOOM:				strcopy(buffer, maxlen, "鼠标中键");
		case IN_SCORE:				strcopy(buffer, maxlen, "Tab");
		case IN_SPEED | IN_RELOAD:	strcopy(buffer, maxlen, "Shift+R");
		case IN_DUCK | IN_RELOAD:	strcopy(buffer, maxlen, "蹲+R");
		default:					strcopy(buffer, maxlen, "销毁键");
	}
}

void ParseVmOffset()
{
	char buffer[64], parts[3][16];
	g_cvVmOffset.GetString(buffer, sizeof(buffer));
	int n = ExplodeString(buffer, " ", parts, sizeof(parts), sizeof(parts[]));
	for (int i = 0; i < 3; i++)
		g_fVmOffset[i] = (i < n) ? StringToFloat(parts[i]) : 0.0;
}

void OnGlowCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	for (int m = 0; m < MAT_COUNT; m++)
		RemoveGlow(m);		// rebuilt on next poll with the new values
}

void OnVmOffsetChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ParseVmOffset();
	for (int m = 0; m < MAT_COUNT; m++)
		RemoveCopies(m);	// rebuilt on next poll with the new offset
}

Action Cmd_Debug(int client, int args)
{
	for (int m = 0; m < MAT_COUNT; m++)
	{
		float anchor[3];
		bool hasAnchor = GetMateriaAnchor(m, anchor);
		int carrier = GetClientOfUserId(g_iCarrier[m]);
		char carrierName[MAX_NAME_LENGTH] = "-";
		if (carrier && IsClientInGame(carrier))
			GetClientName(carrier, carrierName, sizeof(carrierName));
		ReplyToCommand(client, "[Mako] %-7s src=%d btn=%d ready=%d carrier=%s glow=%d copy=%d cast=%.0fs ago pos=%s%.0f %.0f %.0f",
			g_sMatName[m], RefToIndex(g_iSourceRef[m][0]), RefToIndex(g_iButtonRef[m]), IsMateriaReady(m),
			carrierName, RefToIndex(g_iGlowRef[m]), RefToIndex(g_iCopyRef[m][0]),
			g_fLastCast[m] > 0.0 ? GetGameTime() - g_fLastCast[m] : -1.0,
			hasAnchor ? "" : "(none) ", anchor[0], anchor[1], anchor[2]);
	}
	if (client && IsClientInGame(client))
	{
		int vm = GetEntPropEnt(client, Prop_Send, "m_hViewModel");
		if (vm != -1)
		{
			float vpos[3], eye[3];
			GetEntPropVector(vm, Prop_Data, "m_vecAbsOrigin", vpos);
			GetClientEyePosition(client, eye);
			ReplyToCommand(client, "[Mako] viewmodel=%d dist to eye=%.1f", vm, GetVectorDistance(vpos, eye));
		}
	}
	return Plugin_Handled;
}
