#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

/// Edge geometry modifier — macOS 26+ MeshInstancesComponent path only.
///
/// MeshInstancesComponent handles cylinder transform (translate + rotate + scale).
/// This modifier reads per-instance visual data (color + alpha) from a custom
/// texture using instance_id(), and passes it to the surface shader via set_color().

[[visible]]
void edgeGeometry(realitykit::geometry_parameters params) RK_AVAILABILITY_IOS_19 RK_AVAILABILITY_MACOS_16
{
    uint idx = params.geometry().instance_id();
    auto texture = params.textures().custom();
    uint width = texture.get_width();
    uint height = texture.get_height();
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    // CPU uploads are row-major; retain exact slot identity across rows.
    float2 uv = (float2(idx % width, idx / width) + 0.5)
        / float2(width, height);
    half4 data = texture.sample(s, uv);
    params.geometry().set_color(float4(data));
}
