// GOG Galaxy 桩库在成就模式下的手写部分（ACH_RELAY=1 时由 build_stubs.sh 加入）。
// 游戏的 Achievements.Set 先调用 Achievements.get_Platform，后者会问 GogGalaxyManager.IsSignedIn：
// 它取 GalaxyInstance.User()，再调用 SignedIn()。普通桩库让 User() 返回 NULL，C# 那边得到 null，调用时抛出
// NullReferenceException，Achievements.Set 就在调用 Steam 之前中止了（移植笔记 10.2）。
// 这里让 User() 返回一个占位对象；它的方法仍然是返回 0 的空实现，所以 SignedIn() 为 false，平台判定为 STEAM。
// Hand-written part of the GOG Galaxy stub in achievement mode (added by build_stubs.sh when ACH_RELAY=1).
// The game's Achievements.Set first calls Achievements.get_Platform, which asks GogGalaxyManager.IsSignedIn: that takes
// GalaxyInstance.User() and calls SignedIn() on it. The plain stub returns NULL from User(), C# gets null and the call
// throws a NullReferenceException, so Achievements.Set stops before it reaches Steam (PORTING_NOTES 10.2).
// Here User() returns a placeholder object; its methods are still empty stubs returning 0, so SignedIn() is false and
// the platform comes out as STEAM.

static uint8_t de_galaxy_user[64];

// override: CSharp_GalaxyfApi_User___
__attribute__((visibility("default"))) void *CSharp_GalaxyfApi_User___(void)
{
    return de_galaxy_user;
}
