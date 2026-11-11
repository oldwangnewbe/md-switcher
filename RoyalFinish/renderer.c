#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include "MinHook.h"
#include "session.h"

typedef struct Il2CppDomain Il2CppDomain;
typedef struct Il2CppThread Il2CppThread;
typedef struct Il2CppAssembly Il2CppAssembly;
typedef struct Il2CppImage Il2CppImage;
typedef struct Il2CppClass Il2CppClass;
typedef struct Il2CppType Il2CppType;
typedef struct MethodInfo MethodInfo;

typedef struct {
    Il2CppDomain *(*domain_get)(void);
    const Il2CppAssembly **(*domain_get_assemblies)(const Il2CppDomain *, size_t *);
    const Il2CppImage *(*assembly_get_image)(const Il2CppAssembly *);
    Il2CppThread *(*thread_attach)(Il2CppDomain *);
    void (*thread_detach)(Il2CppThread *);
    Il2CppClass *(*class_from_name)(const Il2CppImage *, const char *, const char *);
    const MethodInfo *(*class_get_methods)(Il2CppClass *, void **);
    const char *(*method_get_name)(const MethodInfo *);
    uint32_t (*method_get_param_count)(const MethodInfo *);
    const Il2CppType *(*method_get_param)(const MethodInfo *, uint32_t);
    const Il2CppType *(*method_get_return_type)(const MethodInfo *);
    uint32_t (*method_get_flags)(const MethodInfo *, uint32_t *);
    int (*type_get_type)(const Il2CppType *);
} Il2Cpp;

typedef void (*RenderCard)(void *manager, void *renderer, int card_id, int finish_id,
                           void *on_finished, const MethodInfo *method);
typedef void (*RenderMesh)(void *manager, void *renderer, int card_id, int finish_id,
                           void *on_finished, bool low_render_queue, const MethodInfo *method);
typedef int (*GetFinishType)(int card_id, int finish_id, const MethodInfo *method);

static RoyalSession session;
static RenderCard raw_image;
static RenderMesh mesh_renderer;
static const MethodInfo *finish_method;
static GetFinishType get_finish_type;
static LONG initialized;
static LONG initialization_result = 1;
static LONG log_events;
static const int royal_finish_id = 3;
static const int royal_finish_type = 2;

static void log_line(const char *line)
{
    if (!session.log_path[0]) return;
    HANDLE file = CreateFileW(session.log_path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                              NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD written;
    WriteFile(file, line, (DWORD)strlen(line), &written, NULL);
    CloseHandle(file);
}

static int finish_for_card(int card_id, int finish_id, const char *renderer)
{
    if (card_id <= 0 || card_id >= ROYAL_CARD_LIMIT || finish_id < 0 || finish_id >= royal_finish_id ||
        !(session.cards[card_id / 8] & (1u << (card_id % 8))))
        return finish_id;
    // Verify the local build still maps the chosen finish ID to its Royal material.
    if (get_finish_type(card_id, royal_finish_id, finish_method) != royal_finish_type) {
        if (InterlockedIncrement(&log_events) <= 16)
            log_line("Skipped a card because its Royal material mapping did not match.\n");
        return finish_id;
    }
    if (InterlockedIncrement(&log_events) <= 16) {
        char line[100];
        snprintf(line, sizeof(line), "%s card=%d finish=%d->%d\n", renderer, card_id, finish_id, royal_finish_id);
        log_line(line);
    }
    return royal_finish_id;
}

static void render_raw_image(void *manager, void *renderer, int card_id, int finish_id,
                             void *on_finished, const MethodInfo *method)
{
    raw_image(manager, renderer, card_id, finish_for_card(card_id, finish_id, "UI"), on_finished, method);
}

static void render_mesh(void *manager, void *renderer, int card_id, int finish_id,
                        void *on_finished, bool low_render_queue, const MethodInfo *method)
{
    mesh_renderer(manager, renderer, card_id, finish_for_card(card_id, finish_id, "3D"),
                  on_finished, low_render_queue, method);
}

static bool load_api(HMODULE game, Il2Cpp *api)
{
#define LOAD(name) do { api->name = (__typeof__(api->name))GetProcAddress(game, "il2cpp_" #name); if (!api->name) return false; } while (0)
    LOAD(domain_get);
    LOAD(domain_get_assemblies);
    LOAD(assembly_get_image);
    LOAD(thread_attach);
    LOAD(thread_detach);
    LOAD(class_from_name);
    LOAD(class_get_methods);
    LOAD(method_get_name);
    LOAD(method_get_param_count);
    LOAD(method_get_param);
    LOAD(method_get_return_type);
    LOAD(method_get_flags);
    LOAD(type_get_type);
#undef LOAD
    return true;
}

static void *method_address(HMODULE game, const MethodInfo *method)
{
    if (!method) return NULL;
    void *address = *(void *const *)method;
    MEMORY_BASIC_INFORMATION info;
    const DWORD executable = PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
    if (!address || !VirtualQuery(address, &info, sizeof(info)) || info.AllocationBase != game ||
        info.State != MEM_COMMIT || !(info.Protect & executable) || (info.Protect & PAGE_GUARD))
        return NULL;
    return address;
}

static int type_of(const Il2Cpp *api, const Il2CppType *type)
{
    return type ? api->type_get_type(type) : -1;
}

static const MethodInfo *find_method(const Il2Cpp *api, Il2CppClass *type, const char *name, int parameters)
{
    const int i4 = 8, class_type = 18, void_type = 1, bool_type = 2, value_type = 17, static_flag = 0x10;
    void *cursor = NULL;
    const MethodInfo *match = NULL;
    const MethodInfo *method;
    while ((method = api->class_get_methods(type, &cursor))) {
        if (strcmp(api->method_get_name(method), name) ||
            api->method_get_param_count(method) != (uint32_t)parameters) continue;
        uint32_t impl_flags;
        bool is_static = (api->method_get_flags(method, &impl_flags) & static_flag) != 0;
        int result = type_of(api, api->method_get_return_type(method));
        if (parameters > 2) {
            if (is_static || result != void_type ||
                type_of(api, api->method_get_param(method, 0)) != class_type ||
                type_of(api, api->method_get_param(method, 1)) != i4 ||
                type_of(api, api->method_get_param(method, 2)) != i4 ||
                type_of(api, api->method_get_param(method, 3)) != class_type ||
                (parameters == 5 && type_of(api, api->method_get_param(method, 4)) != bool_type)) continue;
        } else if (!is_static || (result != value_type && result != i4) ||
                   type_of(api, api->method_get_param(method, 0)) != i4 ||
                   type_of(api, api->method_get_param(method, 1)) != i4) continue;
        if (match) return NULL;
        match = method;
    }
    return match;
}

static DWORD install_hooks(void)
{
    HMODULE game = NULL;
    Il2CppDomain *domain = NULL;
    Il2Cpp api = {0};
    size_t count = 0;
    const Il2CppAssembly **assemblies = NULL;
    for (int attempt = 0; attempt < 240; ++attempt) {
        if (!game && (game = GetModuleHandleW(L"GameAssembly.dll")) && !load_api(game, &api))
            return 2;
        if (game && (domain = api.domain_get()) &&
            (assemblies = api.domain_get_assemblies(domain, &count)) && count)
            break;
        Sleep(100);
    }
    if (!assemblies || !count) return 3;
    log_line("IL2CPP domain ready.\n");

    Il2CppThread *thread = api.thread_attach(domain);
    if (!thread) return 3;
    log_line("Attached to IL2CPP.\n");
    Il2CppClass *manager = NULL, *finish = NULL;
    for (size_t i = 0; i < count && (!manager || !finish); ++i) {
        const Il2CppImage *image = api.assembly_get_image(assemblies[i]);
        if (!manager) manager = api.class_from_name(image, "YgomGame.Card", "CardMaterialManager");
        if (!finish) finish = api.class_from_name(image, "YgomGame.Card", "CardFinishSetting");
    }
    if (!manager || !finish) {
        api.thread_detach(thread);
        return 4;
    }
    const MethodInfo *raw = find_method(&api, manager, "GetCardMaterialForRawImageAsync", 4);
    const MethodInfo *mesh = find_method(&api, manager, "GetCardMaterialForMeshRendererAsync", 5);
    finish_method = find_method(&api, finish, "GetCardFisnishData", 2);
    if (!finish_method) finish_method = find_method(&api, finish, "GetCardFinishData", 2);
    void *raw_address = method_address(game, raw);
    void *mesh_address = method_address(game, mesh);
    get_finish_type = (GetFinishType)method_address(game, finish_method);
    api.thread_detach(thread);
    if (!raw_address || !mesh_address || !get_finish_type || raw_address == mesh_address) {
        char line[150];
        snprintf(line, sizeof(line), "Renderer signatures: UI=%d 3D=%d finish=%d\n",
                 raw_address != NULL, mesh_address != NULL, get_finish_type != NULL);
        log_line(line);
        return 5;
    }

    log_line("Checked renderer signatures.\n");
    MH_STATUS status = MH_Initialize();
    if (status == MH_OK) status = MH_CreateHook(raw_address, (void *)render_raw_image, (void **)&raw_image);
    if (status == MH_OK) status = MH_CreateHook(mesh_address, (void *)render_mesh, (void **)&mesh_renderer);
    if (status == MH_OK) status = MH_QueueEnableHook(raw_address);
    if (status == MH_OK) status = MH_QueueEnableHook(mesh_address);
    if (status == MH_OK) {
        log_line("Enabling renderer hooks.\n");
        status = MH_ApplyQueued();
    }
    if (status != MH_OK) {
        log_line(MH_StatusToString(status));
        log_line("\n");
        MH_Uninitialize();
        return 6;
    }
    log_line("Royal Finish renderer hooks ready (UI and 3D).\n");
    return 0;
}

__declspec(dllexport) DWORD WINAPI StartRoyalFinish(const RoyalSession *config)
{
    if (!config || config->version != ROYAL_SESSION_VERSION)
        return 1;
    if (InterlockedExchange(&initialized, 1))
        return (DWORD)InterlockedCompareExchange(&initialization_result, 0, 0);
    session = *config;
    session.log_path[ROYAL_LOG_PATH - 1] = L'\0';
    HANDLE log = CreateFileW(session.log_path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                             NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (log != INVALID_HANDLE_VALUE) CloseHandle(log);
    log_line("Royal Finish loader entered game.\n");
    DWORD result = install_hooks();
    if (result) {
        char line[80];
        snprintf(line, sizeof(line), "Royal Finish renderer unavailable (%lu).\n", (unsigned long)result);
        log_line(line);
    }
    InterlockedExchange(&initialization_result, (LONG)result);
    return result;
}
