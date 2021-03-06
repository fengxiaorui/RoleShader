﻿Shader "MW/Player_New" {
    Properties {
        _MainTex ("MainTex", 2D) = "white" {}
		_Color("Color", Color) = (1,1,1,1)
		_BumpScale("Scale", Float) = 1.0
		_BumpMap("Normal Map", 2D) = "bump" {}
		_Glossiness("Smoothness", Range(0.0, 1.0)) = 0.5 //光泽度(1-Roughness)，与常见的粗糙度等价，只是数值上更为直观，值越小越粗糙
		[Gamma] _Metallic("Metallic", Range(0.0, 1.0)) = 0.0 //金属度，这两个值只有在没有_MetallicGlossMap贴图的情况下生效
		_MetallicGlossMap("Metallic", 2D) = "white" {}	//金属度与光泽度贴图，金属度在r通道上，光泽度在a通道上
		_FresnelScale ("Fresnel Scale", Range(0, 1)) = 0.5
		_FresnelPower ("Fresnel Power", Range(0, 1)) = 0.2
		_Cubemap ("Reflection CubeMap", Cube) = "_SkyBox" {} 
		//这边的输出 = (PBSResult * _Realistic + Texture * _RawTexture) * _Power
		//通过控制Realistic来调节物理渲染的影响程度，控制RawTexture来提亮整体的颜色，提高对比度
		//Realistic = 1，RawTexture = 0时为纯物理渲染的结果
		//Realistic = 0，RawTexture = 1时为原始贴图的颜色
		_Realistic("Realistic(物理渲染比例)", Range(0.0, 2.0)) = 1.0
		_RawTexture("RawTex(原始贴图比例)", Range(0.0, 1.0)) = 1.0
		_Power("Power(整体提亮)", Range(1.0, 2.0)) = 1.0
		_SpecularPower("SpecularPower", Range(1.0, 5.0)) = 1.0

		_MixPower ("_Mix Power", Range(0,.9)) = 0
		_MixColor ("_Mix Color", Color) = (0,0,0,1)

		_RimColor ("Rim Color", Color) = (0,0.545,1,1)
		_RimStrength ("Rim Strength", float) = 0
    }
    SubShader {
		//普通显示
		Pass{
			Tags 
			{
				"Queue" = "Geometry" "LightMode" = "ForwardBase"
			}
			CGPROGRAM
			//#pragma vertex vert
			//#pragma fragment frag
			#pragma multi_compile_fog

			#include "UnityCG.cginc"
			#include "AutoLight.cginc"
			#include "UnityStandardBRDF.cginc"
			#include "UnityGlobalIllumination.cginc"
			//PBR所需的参数
			sampler2D   _MainTex;
			float4		_MainTex_ST;
			sampler2D	_BumpMap;
			half		_BumpScale;

			half4		_Color;

			sampler2D	_DetailAlbedoMap;
			float4		_DetailAlbedoMap_ST;

			sampler2D	_DetailMask;
			sampler2D	_DetailNormalMap;
			half		_DetailNormalMapScale;

			sampler2D	_MetallicGlossMap;
			half		_Metallic;
			half		_Glossiness;

			sampler2D	_OcclusionMap;
			half		_OcclusionStrength;

			sampler2D	_ParallaxMap;
			half		_Parallax;
			half		_UVSec;

			half4 		_EmissionColor;
			sampler2D	_EmissionMap;

			fixed _FresnelScale;
			fixed _FresnelPower;
			samplerCUBE _Cubemap;

			//自己添加的参数
			fixed	_MixPower;
			fixed4	_MixColor;
			fixed4  _RimColor;
			fixed   _RimStrength;
			half _Realistic;
			half _RawTexture;
			half _Power;
			half _SpecularPower;
			//顶点着色器输入
			struct VertexInput
			{
				float4 vertex	: POSITION;
				half3 normal	: NORMAL;
				float2 uv0		: TEXCOORD0;
				float2 uv1		: TEXCOORD1;
#if defined(DYNAMICLIGHTMAP_ON) || defined(UNITY_PASS_META)
				float2 uv2		: TEXCOORD2;
#endif
				half4 tangent	: TANGENT;
			};
			//顶点输出到像素着色器
			struct VertexOutputForwardBase
			{
				float4 pos							: SV_POSITION;
				float4 tex							: TEXCOORD0;
				half3 eyeVec 						: TEXCOORD1;
				half4 tangentToWorldAndParallax[3]	: TEXCOORD2;	// [3x3:tangentToWorld | 1x3:viewDirForParallax]
				half4 ambientOrLightmapUV			: TEXCOORD5;	// SH or Lightmap UV
//				SHADOW_COORDS(6)
				UNITY_FOG_COORDS(6)
				half3 reflUVW				: TEXCOORD7;
//
//					// next ones would not fit into SM2.0 limits, but they are always for SM3.0+
//#if UNITY_SPECCUBE_BOX_PROJECTION
//					float3 posWorld					: TEXCOORD8;
//#endif
			};

			half3 Albedo(float4 texcoords)
			{
				half3 albedo = _Color.rgb * tex2D (_MainTex, texcoords.xy).rgb;
				return albedo;
			}
			
			//
			half2 MetallicGloss(float2 uv)
			{
				half2 mg;
			//#ifdef _METALLICGLOSSMAP
			//	mg = tex2D(_MetallicGlossMap, uv.xy).ra;
			//#else
			//	mg = half2(_Metallic, _Glossiness);
			//#endif
				mg = half2(_Metallic, _Glossiness);
				return mg;
			}

			//ShaderLab中片段着色器用来传递数据的通用结构
			struct FragmentCommonData
			{
				half3 diffColor, specColor;
				// Note: oneMinusRoughness & oneMinusReflectivity for optimization purposes, mostly for DX9 SM2.0 level.
				// Most of the math is being done on these (1-x) values, and that saves a few precious ALU slots.
				half oneMinusReflectivity, oneMinusRoughness;
				half3 normalWorld, eyeVec, posWorld;
				half alpha;
				half3 reflUVW;

			#if UNITY_STANDARD_SIMPLE
				half3 tangentSpaceNormal;
			#endif
			};

			#define UNITY_SETUP_BRDF_INPUT MetallicSetup
			inline FragmentCommonData MetallicSetup (float4 i_tex)
			{
				half2 metallicGloss = MetallicGloss(i_tex.xy);
				half metallic = metallicGloss.x;
				half oneMinusRoughness = metallicGloss.y;		// this is 1 minus the square root of real roughness m.

				half oneMinusReflectivity;
				half3 specColor;
				half3 diffColor = DiffuseAndSpecularFromMetallic (Albedo(i_tex), metallic, /*out*/ specColor, /*out*/ oneMinusReflectivity);

				FragmentCommonData o = (FragmentCommonData)0;
				o.diffColor = diffColor;
				o.specColor = specColor;
				o.oneMinusReflectivity = oneMinusReflectivity;
				o.oneMinusRoughness = oneMinusRoughness;
				return o;
			} 

			inline UnityGI FragmentGI(FragmentCommonData s, half occlusion, half4 i_ambientOrLightmapUV, half atten, UnityLight light, bool reflections)
			{
				UnityGIInput d;
				d.light = light;
				d.worldPos = s.posWorld;
				d.worldViewDir = -s.eyeVec;
				d.atten = atten;
#if defined(LIGHTMAP_ON) || defined(DYNAMICLIGHTMAP_ON)
				d.ambient = 0;
				d.lightmapUV = i_ambientOrLightmapUV;
#else
				d.ambient = i_ambientOrLightmapUV.rgb;
				d.lightmapUV = 0;
#endif
				d.boxMax[0] = unity_SpecCube0_BoxMax;
				d.boxMin[0] = unity_SpecCube0_BoxMin;
				d.probePosition[0] = unity_SpecCube0_ProbePosition;
				d.probeHDR[0] = unity_SpecCube0_HDR;

				d.boxMax[1] = unity_SpecCube1_BoxMax;
				d.boxMin[1] = unity_SpecCube1_BoxMin;
				d.probePosition[1] = unity_SpecCube1_ProbePosition;
				d.probeHDR[1] = unity_SpecCube1_HDR;

				if (reflections)
				{
					Unity_GlossyEnvironmentData g;
					g.roughness = 1 - s.oneMinusRoughness;
#if UNITY_OPTIMIZE_TEXCUBELOD || UNITY_STANDARD_SIMPLE
					g.reflUVW = s.reflUVW;
#else
					g.reflUVW = reflect(s.eyeVec, s.normalWorld);
#endif

					return UnityGlobalIllumination(d, occlusion, s.normalWorld, g);
				}
				else
				{
					return UnityGlobalIllumination(d, occlusion, s.normalWorld);
				}
			}

			inline UnityGI FragmentGI(FragmentCommonData s, half occlusion, half4 i_ambientOrLightmapUV, half atten, UnityLight light)
			{
				return FragmentGI(s, occlusion, i_ambientOrLightmapUV, atten, light, true);
			}

			#define UNITY_BRDF_PBS BRDF1_Unity_PBS

			//-------------------------------------------------------------------------------------
			// counterpart for NormalizePerPixelNormal
			// skips normalization per-vertex and expects normalization to happen per-pixel
			// 这里不进行标准化而放到逐像素中处理
			half3 NormalizePerVertexNormal(float3 n) // takes float to avoid overflow
			{
				return n; // will normalize per-pixel instead
			}
			//像素着色器中对法线进行标准化
			half3 NormalizePerPixelNormal(half3 n)
			{
				return normalize(n);
			}

			inline half4 VertexGIForward(VertexInput v, float3 posWorld, half3 normalWorld)
			{
				half4 ambientOrLightmapUV = 0;
				// Static lightmaps
#ifndef LIGHTMAP_OFF
				ambientOrLightmapUV.xy = v.uv1.xy * unity_LightmapST.xy + unity_LightmapST.zw;
				ambientOrLightmapUV.zw = 0;
				// Sample light probe for Dynamic objects only (no static or dynamic lightmaps)
#elif UNITY_SHOULD_SAMPLE_SH
	#ifdef VERTEXLIGHT_ON
					// Approximated illumination from non-important point lights
					ambientOrLightmapUV.rgb = Shade4PointLights(
						unity_4LightPosX0, unity_4LightPosY0, unity_4LightPosZ0,
						unity_LightColor[0].rgb, unity_LightColor[1].rgb, unity_LightColor[2].rgb, unity_LightColor[3].rgb,
						unity_4LightAtten0, posWorld, normalWorld);
	#endif

				ambientOrLightmapUV.rgb = ShadeSHPerVertex(normalWorld, ambientOrLightmapUV.rgb);
#endif

#ifdef DYNAMICLIGHTMAP_ON
				ambientOrLightmapUV.zw = v.uv2.xy * unity_DynamicLightmapST.xy + unity_DynamicLightmapST.zw;
#endif
				return ambientOrLightmapUV;
			}

#define IN_VIEWDIR4PARALLAX(i) half3(0,0,0)
#define IN_VIEWDIR4PARALLAX_FWDADD(i) half3(0,0,0)
#define IN_WORLDPOS(i) half3(0,0,0)
#define FRAGMENT_SETUP(x) FragmentCommonData x = FragmentSetup(i.tex, i.eyeVec, IN_VIEWDIR4PARALLAX(i), i.tangentToWorldAndParallax, IN_WORLDPOS(i));

			half Alpha(float2 uv)
			{
				return tex2D(_MainTex, uv).a * _Color.a;
			}

			half3 NormalInTangentSpace(float4 texcoords)
			{
				half3 normalTangent = UnpackScaleNormal(tex2D(_BumpMap, texcoords.xy), _BumpScale);
				return normalTangent;
			}

			half3 PerPixelWorldNormal(float4 i_tex, half4 tangentToWorld[3])
			{
				half3 tangent = tangentToWorld[0].xyz;
				half3 binormal = tangentToWorld[1].xyz;
				half3 normal = tangentToWorld[2].xyz;

				half3 normalTangent = NormalInTangentSpace(i_tex);
				half3 normalWorld = NormalizePerPixelNormal(tangent * normalTangent.x + binormal * normalTangent.y + normal * normalTangent.z); // @TODO: see if we can squeeze this normalize on SM2.0 as well
				return normalWorld;
			}

			inline FragmentCommonData FragmentSetup(float4 i_tex, half3 i_eyeVec, half3 i_viewDirForParallax, half4 tangentToWorld[3], half3 i_posWorld)
			{
				//i_tex = Parallax(i_tex, i_viewDirForParallax);

				half alpha = Alpha(i_tex.xy);
#if defined(_ALPHATEST_ON)
				clip(alpha - _Cutoff);
#endif
				FragmentCommonData o = UNITY_SETUP_BRDF_INPUT(i_tex);
				o.normalWorld = PerPixelWorldNormal(i_tex, tangentToWorld);
				o.eyeVec = NormalizePerPixelNormal(i_eyeVec);
				o.posWorld = i_posWorld;

				// NOTE: shader relies on pre-multiply alpha-blend (_SrcBlend = One, _DstBlend = OneMinusSrcAlpha)
				o.diffColor = PreMultiplyAlpha(o.diffColor, alpha, o.oneMinusReflectivity, /*out*/ o.alpha);
				return o;
			}
// ------------------------------------------------------------------
//  Base forward pass (directional light, emission, lightmaps, ...)
			float4 TexCoords(VertexInput v)
			{
				float4 texcoord;
				texcoord.xy = TRANSFORM_TEX(v.uv0, _MainTex); // Always source from uv0
				texcoord.zw = TRANSFORM_TEX(((_UVSec == 0) ? v.uv0 : v.uv1), _DetailAlbedoMap);
				return texcoord;
			}

			VertexOutputForwardBase vertForwardBase(VertexInput v)
			{
				VertexOutputForwardBase o;
				UNITY_INITIALIZE_OUTPUT(VertexOutputForwardBase, o);

				float4 posWorld = mul(_Object2World, v.vertex);
#if UNITY_SPECCUBE_BOX_PROJECTION
				o.posWorld = posWorld.xyz;
#endif
				o.pos = mul(UNITY_MATRIX_MVP, v.vertex);
				o.tex = TexCoords(v);
				o.eyeVec = NormalizePerVertexNormal(posWorld.xyz - _WorldSpaceCameraPos);
				float3 normalWorld = UnityObjectToWorldNormal(v.normal);
//#ifdef _TANGENT_TO_WORLD
				float4 tangentWorld = float4(UnityObjectToWorldDir(v.tangent.xyz), v.tangent.w);

				float3x3 tangentToWorld = CreateTangentToWorldPerVertex(normalWorld, tangentWorld.xyz, tangentWorld.w);
				o.tangentToWorldAndParallax[0].xyz = tangentToWorld[0];
				o.tangentToWorldAndParallax[1].xyz = tangentToWorld[1];
				o.tangentToWorldAndParallax[2].xyz = tangentToWorld[2];
//#else
				//o.tangentToWorldAndParallax[0].xyz = 0;
				//o.tangentToWorldAndParallax[1].xyz = 0;
				//o.tangentToWorldAndParallax[2].xyz = normalWorld;
//#endif
				//We need this for shadow receving
				TRANSFER_SHADOW(o);

				o.ambientOrLightmapUV = VertexGIForward(v, posWorld, normalWorld);
				o.reflUVW = reflect(o.eyeVec, normalWorld);

				UNITY_TRANSFER_FOG(o, o.pos);
				return o;
			}

			UnityLight MainLight(half3 normalWorld)
			{
				UnityLight l;
				l.color = _LightColor0.rgb;
				l.dir = _WorldSpaceLightPos0.xyz;
				l.ndotl = LambertTerm(normalWorld, l.dir);
				return l;
			}

			half Occlusion(float2 uv)
			{
#if (SHADER_TARGET < 30)
				// SM20: instruction count limitation
				// SM20: simpler occlusion
				return tex2D(_OcclusionMap, uv).g;
#else
				half occ = tex2D(_OcclusionMap, uv).g;
				return LerpOneTo(occ, _OcclusionStrength);
#endif
			}

			half4 OutputForward(half4 output, half alphaFromSurface)
			{
#if defined(_ALPHABLEND_ON) || defined(_ALPHAPREMULTIPLY_ON)
				output.a = alphaFromSurface;
#else
				UNITY_OPAQUE_ALPHA(output.a);
#endif
				return output;
			}

			half4 fragForwardBaseInternal(VertexOutputForwardBase i)  
			{
				FRAGMENT_SETUP(s)
				s.reflUVW = i.reflUVW;
				UnityLight mainLight = MainLight(s.normalWorld);
				half atten = SHADOW_ATTENUATION(i);

				half occlusion = Occlusion(i.tex.xy);
				UnityGI gi = FragmentGI(s, occlusion, i.ambientOrLightmapUV, atten, mainLight);
				//return fixed4(gi.light.color, 1.0f);
				half4 c = UNITY_BRDF_PBS(s.diffColor, s.specColor, s.oneMinusReflectivity, s.oneMinusRoughness, s.normalWorld, -s.eyeVec, gi.light, gi.indirect);
				//c.rgb += UNITY_BRDF_GI(s.diffColor, s.specColor, s.oneMinusReflectivity, s.oneMinusRoughness, s.normalWorld, -s.eyeVec, occlusion, gi);	//全局光照计算
				//c.rgb += Emission(i.tex.xy); //自发光0

				half4 tex = tex2D(_MainTex, i.tex.xy);
				//half4 tex = half4(s.diffColor, 1.0f);//这个颜色经过了
				//c = lerp(c, tex, _Realistic);
				fixed3 reflection = texCUBE(_Cubemap, s.reflUVW).rgb;
				fixed fresnel = _FresnelScale + (1 - _FresnelScale) * pow(1 - dot(-s.eyeVec, s.normalWorld), 5);
				c.rgb = lerp(c.rgb,reflection,saturate(fresnel)*_FresnelPower);//saturate(fresnel)
				//c.rgb = c.rgb + reflection * saturate(fresnel) * _FresnelPower;//saturate(fresnel)
				//return c;
				//这里如果_Realistic = 0,_Power = 1,则结果为默认的PBS渲染结果
				c = (c * _Realistic + tex * _RawTexture) * _Power;
				UNITY_APPLY_FOG(i.fogCoord, c.rgb);
				return c;
				//return OutputForward(c, s.alpha);
			}

			VertexOutputForwardBase vertBase(VertexInput v) { return vertForwardBase(v); }
			half4 fragBase(VertexOutputForwardBase i) : SV_Target{ return fragForwardBaseInternal(i); }

			#pragma vertex vertBase
			#pragma fragment fragBase

			///////////////////////////////////////////////////
			//struct v2f{
			//	fixed4 sv_pos: SV_POSITION;
			//	fixed4 uv: TEXCOORD0;
			//	UNITY_FOG_COORDS(1)
			//	//rim  
			//	float3 normal: TEXCOORD2;     
			//	float3 viewDir: TEXCOORD3;  
			//};

			//v2f vert(appdata_base v)
			//{
			//	v2f o;
			//	o.sv_pos = mul(UNITY_MATRIX_MVP, v.vertex);
			//	UNITY_TRANSFER_FOG(o,o.sv_pos);
			//	o.uv = v.texcoord;
			//	//
			//	o.normal = v.normal;
			//	o.viewDir = ObjSpaceViewDir(v.vertex).xyz;
			//	return o;
			//}

			//fixed4 frag(v2f i): SV_Target
			//{
			//	fixed4 c = tex2D(_MainTex, i.uv);

			//	//灰度值
			//	fixed gray = dot(c.rgb, fixed3(0.3, 0.6, 0.1));

			//	//fog颜色处理
			//	UNITY_APPLY_FOG(i.fogCoord, c);

			//	//自定义混合色处理(目前用于闪白)
			//	c.rgb += gray.r * _MixPower * _MixColor.rgb * 2;

			//	//初始化金属度和光泽度需要的输入参数(从MetallicGloss中采样)
			//	FragmentCommonData o = MetallicSetup(i.uv);

			//	//从法线贴图中取得对应的法线信息

			//	//o.normalWorld = PerPixelWorldNormal(i.uv, tangentToWorld);
			//	//o.eyeVec = NormalizePerPixelNormal(i_eyeVec);
			//	//o.posWorld = i_posWorld;






			//	fixed3 diffColor = o.diffColor;
			//	fixed3 specColor = o.specColor;
			//	return fixed4(diffColor.rgb, 1.0f);




			//	//边缘高亮
			//	//fixed dot_v = dot(i.normal, normalize(i.viewDir));
			//	//c.rgb += _RimColor * pow(clamp(1 - dot_v, 0, 1), 1.3f) * 1.5f * _RimStrength;
			//	//return c;
			//}
			ENDCG
		}
		// Pass to render object as a shadow caster, required to write to depth texture
		Pass 
		{
			Name "ShadowCaster"
			Tags { "LightMode" = "ShadowCaster" }
		}
    }
}
