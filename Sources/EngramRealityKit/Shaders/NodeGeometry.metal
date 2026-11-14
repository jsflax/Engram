#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

/// Node geometry modifier for < macOS 26 (two-buffer LowLevelMesh path).
///
/// Reads per-instance data from vertex attributes (buffer 1):
/// - color(float4): (offsetX, offsetY, offsetZ, scale)
/// - uv2(float4):   (colorR, colorG, colorB, dyingAlpha)
///
/// Transforms template sphere verts to world position and passes visual data
/// to the surface shader via set_color().

[[visible]]
void nodeGeometryTwoBuffer(realitykit::geometry_parameters params)
{
    float4 geoData = params.geometry().color();    // (ox, oy, oz, scale)
    float4 visData = params.geometry().uv2();       // (cr, cg, cb, alpha)

    float3 localPos = params.geometry().model_position();
    float3 offset = geoData.xyz;
    float scale = geoData.w;

    // Transform: move template vert to world position with scale.
    // localPos is unit sphere normal. Final position = offset + localPos * scale.
    // Offset from current = (offset + localPos * scale) - localPos.
    params.geometry().set_model_position_offset(offset + localPos * scale - localPos);

    // Pass visual data to surface shader as vertex color
    params.geometry().set_color(visData);
}

/// Node geometry modifier for macOS 26+ (MeshInstancesComponent path).
///
/// MeshInstancesComponent handles position/scale via instance transforms.
/// Reads per-instance visual data from custom texture using instance_id().
/// Passes color to surface shader via set_color().

[[visible]]
void nodeGeometryInstanced(realitykit::geometry_parameters params) RK_AVAILABILITY_IOS_19 RK_AVAILABILITY_MACOS_16
{
    uint idx = params.geometry().instance_id();
    float texWidth = params.uniforms().custom_parameter().y;
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float2 uv = float2((float(idx) + 0.5) / texWidth, 0.5);
    half4 data = params.textures().custom().sample(s, uv);
    params.geometry().set_color(float4(data));
}
