"""Deterministic CPU IBL reference bake (run with Blender's bundled NumPy).
RGBA16F little-endian, latitude v=asin(y)/pi+0.5, six GGX levels in a vertical atlas.
"""
import json
import math
from pathlib import Path
import numpy as np


def normalize(value):
    return value / np.maximum(np.linalg.norm(value, axis=-1, keepdims=True), 1e-10)


def studio(direction):
    height = direction[..., 1:2]
    floor = np.array([0.09, 0.1, 0.13])
    sky = np.array([0.3, 0.44, 0.65])
    radiance = floor + (sky - floor) * np.clip(height * 0.5 + 0.5, 0, 1)
    for axis, color, strength, power in [
        ((-0.4, 0.8, -0.5), (1.0, 0.83, 0.63), 18, 48),
        ((0.8, 0.35, 0.25), (0.55, 0.75, 1.0), 4, 18),
        ((0.1, 0.9, 0.65), (1.0, 0.95, 0.83), 7, 30),
    ]:
        facing = np.clip(np.sum(direction * normalize(np.array(axis)), axis=-1), 0, 1)
        radiance = radiance + np.power(facing, power)[..., None] * np.array(color) * strength
    return radiance


def directions(width, height):
    u, v = np.meshgrid((np.arange(width) + 0.5) / width, (np.arange(height) + 0.5) / height)
    longitude = (u - 0.5) * math.tau
    latitude = (v - 0.5) * math.pi
    return np.stack([np.cos(latitude) * np.cos(longitude), np.sin(latitude), np.cos(latitude) * np.sin(longitude)], axis=-1)


def sequence(count):
    indices = np.arange(count, dtype=np.uint32)
    bits = indices.copy()
    bits = (bits << 16) | (bits >> 16)
    bits = ((bits & 0x55555555) << 1) | ((bits & 0xAAAAAAAA) >> 1)
    bits = ((bits & 0x33333333) << 2) | ((bits & 0xCCCCCCCC) >> 2)
    bits = ((bits & 0x0F0F0F0F) << 4) | ((bits & 0xF0F0F0F0) >> 4)
    bits = ((bits & 0x00FF00FF) << 8) | ((bits & 0xFF00FF00) >> 8)
    return np.stack([indices / count, bits * 2.3283064365386963e-10], axis=-1)


def frame(normal):
    axis = np.zeros_like(normal)
    axis[..., 1] = 1
    axis[np.abs(normal[..., 1]) > 0.99] = [1, 0, 0]
    tangent = normalize(np.cross(axis, normal))
    return tangent, np.cross(normal, tangent)


def irradiance(normal, environment=studio, count=256):
    tangent, bitangent = frame(normal)
    result = np.zeros_like(normal)
    for u, v in sequence(count):
        radius = math.sqrt(v)
        sample = tangent * (radius * math.cos(math.tau * u)) + bitangent * (radius * math.sin(math.tau * u)) + normal * math.sqrt(1 - v)
        result += environment(sample)
    return result * (math.pi / count)


def specular(normal, roughness, environment=studio, count=256):
    if roughness == 0:
        return environment(normal)
    tangent, bitangent = frame(normal)
    result = np.zeros_like(normal)
    weight = np.zeros(normal.shape[:-1])
    alpha = roughness * roughness
    for u, v in sequence(count):
        cos_theta = math.sqrt((1 - v) / (1 + (alpha * alpha - 1) * v))
        sin_theta = math.sqrt(max(0, 1 - cos_theta * cos_theta))
        half = tangent * (sin_theta * math.cos(math.tau * u)) + bitangent * (sin_theta * math.sin(math.tau * u)) + normal * cos_theta
        light = normalize(2 * np.sum(normal * half, axis=-1, keepdims=True) * half - normal)
        ndotl = np.clip(np.sum(normal * light, axis=-1), 0, 1)
        result += environment(light) * ndotl[..., None]
        weight += ndotl
    return result / np.maximum(weight[..., None], 1e-8)


def brdf_lut(size=64, count=256):
    ndotv, roughness = np.meshgrid((np.arange(size) + 0.5) / size, (np.arange(size) + 0.5) / size)
    view = np.stack([np.sqrt(1 - ndotv * ndotv), np.zeros_like(ndotv), ndotv], axis=-1)
    result = np.zeros((size, size, 2))
    alpha = roughness * roughness
    k = roughness * roughness / 2
    for u, v in sequence(count):
        cos_theta = np.sqrt((1 - v) / (1 + (alpha * alpha - 1) * v))
        sin_theta = np.sqrt(np.maximum(0, 1 - cos_theta * cos_theta))
        half = np.stack([sin_theta * math.cos(math.tau * u), sin_theta * math.sin(math.tau * u), cos_theta], axis=-1)
        vdoth = np.clip(np.sum(view * half, axis=-1), 0, 1)
        light = 2 * vdoth[..., None] * half - view
        ndotl = np.clip(light[..., 2], 0, 1)
        geometry = ndotv / (ndotv * (1 - k) + k) * ndotl / np.maximum(ndotl * (1 - k) + k, 1e-8)
        visibility = geometry * vdoth / np.maximum(cos_theta * ndotv, 1e-8)
        fresnel = np.power(1 - vdoth, 5)
        valid = ndotl > 0
        result[..., 0] += np.where(valid, (1 - fresnel) * visibility, 0)
        result[..., 1] += np.where(valid, fresnel * visibility, 0)
    return result / count


def write_half(path, values):
    rgba = np.ones(values.shape[:-1] + (4,))
    rgba[..., :values.shape[-1]] = values
    rgba.astype('<f2').tofile(path)


def bake(output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    normal = directions(128, 64)
    diffuse = irradiance(directions(32, 16))
    levels = np.concatenate([specular(normal, level / 5) for level in range(6)], axis=0)
    lut = brdf_lut()
    radiance = studio(directions(256, 128))
    write_half(output / 'Studio-radiance.rgba16f', radiance)
    write_half(output / 'Studio-irradiance.rgba16f', diffuse)
    write_half(output / 'Studio-specular.rgba16f', levels)
    write_half(output / 'Studio-brdf.rgba16f', lut)
    manifest = {
        'version': 1, 'radiance': {'file':'Studio-radiance.rgba16f','width':256,'height':128}, 'irradiance': {'file': 'Studio-irradiance.rgba16f', 'width': 32, 'height': 16},
        'specular': {'file': 'Studio-specular.rgba16f', 'width': 128, 'height': 384},
        'brdf': {'file': 'Studio-brdf.rgba16f', 'width': 64, 'height': 64}, 'specularLevels': 6,
    }
    (output / 'Studio.ibl').write_text(json.dumps(manifest, indent=2) + '\n')
    return studio(directions(256, 128))


def self_test():
    normal = directions(8, 4)
    constant = lambda d: np.broadcast_to(np.array([0.25, 0.5, 2.0]), d.shape)
    np.testing.assert_allclose(irradiance(normal, constant), constant(normal) * math.pi, atol=1e-10)
    for roughness in (0, 0.2, 0.6, 1):
        np.testing.assert_allclose(specular(normal, roughness, constant), constant(normal), atol=1e-10)
    lut = brdf_lut(16)
    assert np.isfinite(lut).all() and (lut >= 0).all() and (lut.sum(axis=-1) <= 1.05).all()
    print('IBL bake self-test: constant-radiance energy, GGX preservation, and BRDF LUT passed')
