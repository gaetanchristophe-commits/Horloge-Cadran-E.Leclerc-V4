gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

local font = resource.load_font "font.ttf"
local logo = resource.load_image "logo.png"

-- Couleurs E.Leclerc (approximatives)
local BLEU   = {0.00, 0.36, 0.67}
local ORANGE = {0.97, 0.58, 0.12}
local ROUGE  = {0.85, 0.10, 0.10}
local BLANC  = {1, 1, 1}

local tex_blanc   = resource.create_colored_texture(1, 1, 1, 1)
local tex_bleu   = resource.create_colored_texture(BLEU[1], BLEU[2], BLEU[3], 1)
local tex_rouge   = resource.create_colored_texture(ROUGE[1], ROUGE[2], ROUGE[3], 1)
local tex_bandeau = resource.create_colored_texture(0, 0, 0, 0.25)   -- assombrit le fond derriere la date
local tex_led     = resource.create_colored_texture(0.04, 0.04, 0.04, 1)

-- Fond bleu en degrade vertical : fonce en haut et en bas, plus clair au centre
local shader_fond = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  void main() {
    float t = 1.0 - abs(TexCoord.y * 2.0 - 1.0);
    vec3 bord   = vec3(0.000, 0.188, 0.369);
    vec3 milieu = vec3(0.047, 0.408, 0.722);
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(mix(bord, milieu, t), 1.0);
  }
]]

-- Chiffre d'afficheur LED 7 segments : segments biseautes, inclines, rouges.
-- Unites internes : chiffre de 20 x 40, segments de 4.4 d'epaisseur.
local LED_X0, LED_XW, LED_Y0, LED_YH = -3.0, 31.6, -3.0, 46.0   -- zone dessinee autour du chiffre
local shader_chiffre = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float sa, sb, sc, sd, se, sf, sg;   // 1 = segment allume
  uniform float px;                           // taille d'un pixel en unites
  const float W = 20.0;
  const float H = 40.0;
  const float T = 4.4;
  const float G = 1.1;
  const float K = 0.14;                       // inclinaison (environ 8 degres)

  float couvre(float d) { return clamp(d / px + 0.5, 0.0, 1.0); }

  float hseg(vec2 p, vec2 o) {
    vec2 q = p - o;
    float L = W - 2.0 * G;
    float demi = min(T * 0.5, min(q.x, L - q.x));
    return couvre(demi - abs(q.y));
  }

  float vseg(vec2 p, vec2 o) {
    vec2 q = p - o;
    float L = H * 0.5 - 2.0 * G;
    float demi = min(T * 0.5, min(q.y, L - q.y));
    return couvre(demi - abs(q.x));
  }

  void main() {
    vec2 p = vec2(-3.0 + TexCoord.x * 31.6, -3.0 + TexCoord.y * 46.0);
    p.x -= (H - p.y) * K;
    float a = hseg(p, vec2(G, 0.0));
    float g = hseg(p, vec2(G, H * 0.5));
    float d = hseg(p, vec2(G, H));
    float f = vseg(p, vec2(0.0, G));
    float b = vseg(p, vec2(W, G));
    float e = vseg(p, vec2(0.0, H * 0.5 + G));
    float c = vseg(p, vec2(W, H * 0.5 + G));
    float tout    = max(max(max(a, b), max(c, d)), max(max(e, f), g));
    float allume  = max(max(max(a * sa, b * sb), max(c * sc, d * sd)),
                        max(max(e * se, f * sf), g * sg));
    vec3 eteint = vec3(0.18, 0.04, 0.03);
    vec3 rouge  = vec3(1.00, 0.165, 0.10);
    vec3 col = mix(eteint, rouge, allume / max(tout, 0.001));
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(col, tout);
  }
]]

-- Disque ou anneau lisse, dessine par un shader (pas d'image necessaire)
local shader_disque = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float interieur;
  uniform float flou;
  uniform float r, g, b;
  void main() {
    float d = length(TexCoord - vec2(0.5)) * 2.0;
    float a = (1.0 - smoothstep(1.0 - flou, 1.0, d)) * smoothstep(interieur - flou, interieur, d);
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(r, g, b, a);
  }
]]

local JOURS = {"DIMANCHE","LUNDI","MARDI","MERCREDI","JEUDI","VENDREDI","SAMEDI"}
local MOIS  = {"JANVIER","FÉVRIER","MARS","AVRIL","MAI","JUIN","JUILLET",
               "AOÛT","SEPTEMBRE","OCTOBRE","NOVEMBRE","DÉCEMBRE"}

-- Reglages (modifiables depuis le tableau de bord info-beamer)
local trotteuse = true

util.json_watch("config.json", function(config)
  if config.trotteuse ~= nil then trotteuse = config.trotteuse end
end)

-- Heure d'été européenne automatique (France)
local function jour_semaine(y, m, d)   -- 0 = dimanche
  local t = {0,3,2,5,0,3,5,2,6,4,2,4}
  if m < 3 then y = y - 1 end
  return (y + math.floor(y/4) - math.floor(y/100) + math.floor(y/400) + t[m] + d) % 7
end

local function decalage(utc)
  local debut = 3 * 10000 + (31 - jour_semaine(utc.year, 3, 31)) * 100 + 1
  local fin   = 10 * 10000 + (31 - jour_semaine(utc.year, 10, 31)) * 100 + 1
  local now   = utc.month * 10000 + utc.day * 100 + utc.hour
  if now >= debut and now < fin then return 7200 end
  return 3600
end

local function disque(cx, cy, rayon, c, interieur)
  shader_disque:use{
    interieur = interieur or 0,
    flou = 1.5 / rayon,
    r = c[1], g = c[2], b = c[3],
  }
  tex_blanc:draw(cx - rayon, cy - rayon, cx + rayon, cy + rayon)
  shader_disque:deactivate()
end

-- Rectangle tourne autour du centre du cadran (angle en degres, 0 = midi)
-- de "debut" a "fin" le long du rayon (negatif = cote oppose)
local function trait(cx, cy, angle, debut, fin, largeur, tex)
  gl.pushMatrix()
  gl.translate(cx, cy)
  gl.rotate(angle, 0, 0, 1)
  tex:draw(-largeur / 2, -fin, largeur / 2, -debut)
  gl.popMatrix()
end

local function centre(texte, x, y, taille, c)
  local w = font:width(texte, taille)
  font:write(x - w / 2, y - taille / 2, texte, taille, c[1], c[2], c[3], 1)
end

local function cadran(cx, cy, R)
  -- Lunette orange, face blanche
  disque(cx, cy, R, ORANGE)
  disque(cx, cy, R * 0.95, BLANC)

  -- Graduations : minutes fines, heures epaisses
  for i = 0, 59 do
    if i % 5 == 0 then
      trait(cx, cy, i * 6, R * 0.80, R * 0.91, R * 0.022, tex_bleu)
    else
      trait(cx, cy, i * 6, R * 0.87, R * 0.91, R * 0.007, tex_bleu)
    end
  end

  for h = 1, 12 do
    local a = math.rad(h * 30)
    centre(tostring(h), cx + math.sin(a) * R * 0.68, cy - math.cos(a) * R * 0.68,
           R * 0.15, BLEU)
  end
end

local function logo_cadran(cx, cy, R)
  local iw, ih = logo:size()
  local lw = R * 0.80
  local lh = lw * ih / iw
  local y  = cy - R * 0.36 - lh / 2
  logo:draw(cx - lw / 2, y, cx + lw / 2, y + lh)
end

-- Aiguille aux deux bouts arrondis
local function aiguille(cx, cy, angle, debut, fin, largeur, tex, c)
  trait(cx, cy, angle, debut, fin, largeur, tex)
  local a = math.rad(angle)
  local sx, sy = math.sin(a), -math.cos(a)
  disque(cx + sx * fin,   cy + sy * fin,   largeur / 2, c)
  disque(cx + sx * debut, cy + sy * debut, largeur / 2, c)
end

local function aiguilles(cx, cy, R, d)
  local m = d.min + d.sec / 60
  local h = (d.hour % 12) + m / 60

  aiguille(cx, cy, h * 30, -R * 0.10, R * 0.50, R * 0.075, tex_bleu, BLEU)
  aiguille(cx, cy, m * 6,  -R * 0.12, R * 0.78, R * 0.035, tex_bleu, BLEU)
  disque(cx, cy, R * 0.07, BLEU)

  if trotteuse then
    aiguille(cx, cy, d.sec * 6, -R * 0.20, R * 0.86, R * 0.012, tex_rouge, ROUGE)
    disque(cx, cy, R * 0.035, ROUGE)
  end
end

-- Afficheur LED 7 segments
local SEGMENTS = {
  ["0"] = "abcdef", ["1"] = "bc",    ["2"] = "abged", ["3"] = "abgcd",   ["4"] = "fgbc",
  ["5"] = "afgcd",  ["6"] = "afgedc", ["7"] = "abc",  ["8"] = "abcdefg", ["9"] = "abcfgd",
}
local LED_ROUGE  = {1.00, 0.165, 0.10}
local LED_ETEINT = {0.18, 0.04, 0.03}
local LED_PENTE  = 0.14

-- Chiffre dont le coin haut gauche est en (x, y), s = pixels par unite
local function chiffre_led(ch, x, y, s)
  local on = SEGMENTS[ch]
  local u = {px = 1 / s}
  for seg in ("abcdefg"):gmatch(".") do
    u["s" .. seg] = on:find(seg) and 1 or 0
  end
  shader_chiffre:use(u)
  tex_blanc:draw(x + LED_X0 * s, y + LED_Y0 * s,
                 x + (LED_X0 + LED_XW) * s, y + (LED_Y0 + LED_YH) * s)
  shader_chiffre:deactivate()
end

-- Heure "HH:MM" centree en (cx, cy) sur un fond noir, s = pixels par unite
local LED_LARGEUR = 4 * 20 + 3 * 8 + 14 + 40 * LED_PENTE   -- en unites
local LED_HAUTEUR = 40
local LED_MARGE   = 7

local function afficheur_led(heure, cx, cy, s, deux_points)
  local w = LED_LARGEUR * s
  local x = cx - w / 2
  local y = cy - LED_HAUTEUR * s / 2
  local m = LED_MARGE * s
  tex_led:draw(x - m, y - m, x + w + m, y + LED_HAUTEUR * s + m)

  chiffre_led(heure:sub(1, 1), x,              y, s)
  chiffre_led(heure:sub(2, 2), x + 28 * s,     y, s)
  chiffre_led(heure:sub(4, 4), x + 70 * s,     y, s)
  chiffre_led(heure:sub(5, 5), x + 98 * s,     y, s)

  local c = deux_points and LED_ROUGE or LED_ETEINT
  for _, py in ipairs{13, 29} do
    disque(x + (59 + (40 - py) * LED_PENTE) * s, y + py * s, 2.6 * s, c)
  end
end

-- Mois/annee a gauche et jour/quantieme a droite du cadran, sur un bandeau sombre.
-- L'annee et le quantieme sont nettement plus grands que le mois et le jour.
local GRAND = 1.8

local function dates_cotes(cx, cy, R, d)
  local gauche = {MOIS[d.month], tostring(d.year)}
  local droite = {JOURS[d.wday], tostring(d.day)}

  local cote  = cx - R                -- largeur libre de chaque cote
  local max_w = cote * 0.82
  local taille = HEIGHT * 0.075
  for _, texte in ipairs{gauche[1], droite[1]} do
    local w = font:width(texte, taille)
    if w > max_w then taille = taille * max_w / w end
  end
  local w = font:width(gauche[2], taille * GRAND)
  if w > max_w then taille = taille * max_w / w end
  local grand = taille * GRAND

  local ecart = taille * 0.25
  local marge = taille * 0.40
  local haut  = cy - (taille + ecart + grand) / 2
  local bas   = haut + taille + ecart + grand
  tex_bandeau:draw(0, haut - marge, WIDTH, bas + marge)

  local y1 = haut + taille / 2
  local y2 = bas - grand / 2
  local xg = cote / 2
  local xd = WIDTH - cote / 2
  centre(gauche[1], xg, y1, taille, BLANC)
  centre(gauche[2], xg, y2, grand,  BLANC)
  centre(droite[1], xd, y1, taille, BLANC)
  centre(droite[2], xd, y2, grand,  BLANC)

  -- Heure digitale 24 h facon afficheur LED, centree sous le jour
  local heure  = string.format("%02d:%02d", d.hour, d.min)
  local haut_h = bas + marge
  local bas_h  = HEIGHT * 0.96
  local s = math.min(max_w / (LED_LARGEUR + 2 * LED_MARGE),
                     (bas_h - haut_h) * 0.65 / (LED_HAUTEUR + 2 * LED_MARGE))
  afficheur_led(heure, xd, (haut_h + bas_h) / 2, s, d.sec % 2 == 0)
end

function node.render()
  gl.clear(BLEU[1], BLEU[2], BLEU[3], 1)

  -- Fond en degrade
  shader_fond:use{}
  tex_blanc:draw(0, 0, WIDTH, HEIGHT)
  shader_fond:deactivate()

  -- Heure locale
  local t   = os.time()
  local utc = os.date("!*t", t)
  local d   = os.date("!*t", t + decalage(utc))

  -- Le cadran occupe toute la hauteur entre les bandeaux
  local cx, cy = WIDTH / 2, HEIGHT / 2
  local R = math.min(HEIGHT * 0.455, WIDTH * 0.48)

  dates_cotes(cx, cy, R, d)
  cadran(cx, cy, R)
  logo_cadran(cx, cy, R)
  aiguilles(cx, cy, R, d)
end
