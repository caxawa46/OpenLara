R"====(
#ifdef GL_ES
    precision lowp  int;
    precision highp float;
#endif

varying vec3 vCoord;
varying vec2 vTexCoord;
varying vec4 vProjCoord;
varying vec4 vOldPos;
varying vec4 vNewPos;
varying vec3 vViewVec;
varying vec3 vLightVec;

uniform vec3  uViewPos;
uniform mat4  uViewProj;
uniform vec3  uLightPos;
uniform vec3  uPosScale[2];

uniform vec4  uTexParam;
uniform vec4  uParam;
uniform vec4  uColor;

uniform sampler2D sNormal;

#ifdef VERTEX
    #define ETA_AIR     1.000
    #define ETA_WATER   1.333

    attribute vec4 aCoord;

    void main() {
        vTexCoord = (aCoord.xy * 0.5 + 0.5) * uTexParam.zw;

        #if defined(WATER_MASK) || defined(WATER_COMPOSE)

            float height = 0.0;

            #ifdef WATER_COMPOSE
                #ifdef WATER_USE_GRID
                    vTexCoord = (aCoord.xy * (1.0 / 48.0) * 0.5 + 0.5) * uTexParam.zw;
                    height = texture2D(sNormal, vTexCoord).x;
                #endif
            #endif

            vCoord = vec3(aCoord.x, height, aCoord.y) * uPosScale[1] + uPosScale[0];

            vec4 cp = uViewProj * vec4(vCoord, 1.0);

            vProjCoord  = cp;
            gl_Position = cp;
        #else
            vProjCoord = vec4(0.0);
			vCoord     = vec3(aCoord.xy, 0.0);
            #ifdef WATER_CAUSTICS
                vec3 rCoord = vec3(aCoord.x, aCoord.y, 0.0) * uPosScale[1].xzy;

                vec4 info = texture2D(sNormal, (rCoord.xy  * 0.5 + 0.5) * uTexParam.zw);
                vec3 normal = vec3(info.z, info.w, sqrt(1.0 - dot(info.zw, info.zw)));

                vec3 light = vec3(0.0, 0.0, 1.0);
                vec3 refOld = refract(-light, vec3(0.0, 0.0, 1.0), 0.75);
                vec3 refNew = refract(-light, normal, 0.75);
                
                vOldPos = vec4(rCoord + refOld * (-0.25 / refOld.z) + refOld * ((-refOld.z - 1.0) / refOld.z), 1.0);              
                vNewPos = vec4(rCoord + refNew * ((info.r - 0.25) / refNew.z) + refOld * ((-refNew.z - 1.0) / refOld.z), 1.0);
      
                gl_Position = vec4(vNewPos.xy + refOld.xy / refOld.z, 0.0, 1.0);
            #else
                vOldPos = vNewPos = vec4(0.0);
                gl_Position = vec4(aCoord.xyz, 1.0);
            #endif
        #endif
        vViewVec  = uViewPos  - vCoord.xyz;
        vLightVec = uLightPos - vCoord.xyz;
    }
#else
    uniform sampler2D sDiffuse;
    uniform sampler2D sReflect;
    uniform sampler2D sMask;

    uniform vec4 uLightColor;

    #define PI   3.141592653589793

    float calcFresnel(float NdotL, float fbias, float fpow) {
        float f = 1.0 - abs(NdotL);
        return clamp(fbias + (1.0 - fbias) * pow(f, fpow), 0.0, 1.0);
    }

    vec3 applyFog(vec3 color, vec3 fogColor, float factor) {
        float fog = clamp(1.0 / exp(factor), 0.0, 1.0);
        return mix(fogColor, color, fog);
    }

    vec4 drop() {
        vec2 tc = gl_FragCoord.xy * uTexParam.xy;
        vec4 v = texture2D(sDiffuse, tc);

        float drop = max(0.0, 1.0 - length(uParam.xy - gl_FragCoord.xy) / uParam.z);
        drop = 0.5 - cos(drop * PI) * 0.5;
        v.x += drop * uParam.w;

        return v;
    }

    vec4 calc() {
        vec2 tc = gl_FragCoord.xy * uTexParam.xy;

        if (texture2D(sMask, tc).x == 0.0)
            return vec4(0.0);

        vec4 v = texture2D(sDiffuse, tc); // height, speed, normal.xz

        vec3 d = vec3(uTexParam.xy, 0.0);
        vec4 f = vec4(texture2D(sDiffuse, tc + d.xz).x, texture2D(sDiffuse, tc + d.zy).x,
                      texture2D(sDiffuse, tc - d.xz).x, texture2D(sDiffuse, tc - d.zy).x);
        float average = dot(f, vec4(0.25));

    // normal
        v.zw = normalize( vec3(f.x - f.z, 64.0 / (1024.0 * 2.0), f.y - f.w) ).xz;

    // integrate
        const float vel = 1.4;
        const float vis = 0.995;

        v.y += (average - v.x) * vel;
        v.y *= vis;
        v.x += v.y;

        return v; 
    }

    vec4 caustics() {
        float rOldArea = length(dFdx(vOldPos.xyz)) * length(dFdy(vOldPos.xyz));
        float rNewArea = length(dFdx(vNewPos.xyz)) * length(dFdy(vNewPos.xyz));
        float value = clamp(rOldArea / rNewArea * 0.2, 0.0, 1.0) * vOldPos.w;
        return vec4(vec3(value), 1.0);
    }

    vec4 mask() {
        return vec4(0.0);
    }

    vec4 compose() {
        vec2 tc = vProjCoord.xy / vProjCoord.w * 0.5 + 0.5;

        vec4 value  = texture2D(sNormal, vTexCoord);

        vec3 normal = vec3(value.z, -sqrt(1.0 - dot(value.zw, value.zw)), value.w);

        vec2 dudv   = (uViewProj * vec4(normal.x, 0.0, normal.z, 0.0)).xy;

        vec3 viewVec = normalize(vViewVec);
        vec3 rv = reflect(-viewVec, normal);
        vec3 lv = normalize(vLightVec);

        float spec = pow(max(0.0, dot(rv, lv)), 64.0) * 0.5;

        vec4 refrA = texture2D(sDiffuse, uParam.xy * clamp(tc + dudv * uParam.z, 0.0, 0.999) );
        vec4 refrB = texture2D(sDiffuse, uParam.xy * (tc) );
        vec4 refr  = vec4(mix(refrA.xyz, refrB.xyz, refrA.w), 1.0);
        vec4 refl  = texture2D(sReflect, vec2(tc.x, 1.0 - tc.y) + dudv * uParam.w);

        float fresnel = calcFresnel(dot(normal, viewVec), 0.1, 2.0);

        vec4 color = mix(refr, refl, fresnel) + spec;

        float d = abs((vCoord.y - uViewPos.y) / normalize(vViewVec).y);
        d *= step(0.0, uViewPos.y - vCoord.y); // apply fog only when camera is underwater
        color.xyz = applyFog(color.xyz, uColor.xyz, d * WATER_FOG_DIST);

        return color;
    }   
    
    vec4 pass() {        
        #ifdef WATER_DROP
            return drop();
        #endif

        #ifdef WATER_STEP
            return calc();
        #endif

        #ifdef WATER_CAUSTICS 
            return caustics();
        #endif

        #ifdef WATER_MASK
            return mask();
        #endif

        #ifdef WATER_COMPOSE
            return compose();
        #endif

        return vec4(1.0, 0.0, 1.0, 1.0);
    }
    
    void main() {
        gl_FragColor = pass();
    }
#endif
)===="