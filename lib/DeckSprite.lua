-- The console, as pixel art.
--
-- Authored as text and compiled to an ImageData at load rather than shipped
-- as a PNG.  A mod may live inside a mounted .love archive, so there is no
-- reliable path to load a binary asset from; building it in code sidesteps
-- that entirely, keeps the art reviewable in a diff, and matches how the
-- other mod here builds its textures.
--
-- Four values, matching the four DMG shades the palette pass expects:
--   .  transparent      +  highlight (shade 1)
--   o  body (shade 2)   #  screen / dark (shade 3)

local V = ...

local DeckSprite = {}

DeckSprite.W, DeckSprite.H = 80, 32

local ART = {
  ".......#######....##..##..........................................+######+......",
  "....o##+++++++####++##++##########################################+++++++o#+....",
  "..oo++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++oo+.",
  ".++##o++oo++++++++oo########ooooo##ooo##ooo###ooo###ooo##oooooo+++++++ooo++oo+++",
  "+++#o#++oo++++++++############################################o++++++++o++o+oo++",
  "#o##+##o++++oo++++############################################o+++oo++++oo+ooooo",
  "##oo+oo#+++oo+o+++############################################o+++o+o++o+o++ooo#",
  "##oo+oo#+++o++o+++############################################o++o++oo+ooo+oooo#",
  "#oo#+#oo++##++##++############################################o+o#o+o#o+ooo+ooo#",
  "#o+#o#++++o####o++############################################o+o####o+++oooo+o#",
  "#o+o#o+++++oooo+++############################################o++ooooo++++ooo+o#",
  "#o++++++++++++++++############################################o+++++++++++++++o#",
  "####++++oo###oo#++############################################o+oooo#oooo+++o###",
  "#ooo#++#++++++++#+############################################ooo+++++++oo+oooo#",
  "#ooo#++#++++++++#+############################################ooo+++++++oo+oooo#",
  "#ooo#++#++++++++#+############################################ooo+++++++oo+oooo#",
  "#ooo#++#++++++++#+############################################ooo+++++++oo+oooo#",
  "#ooo#++#++++++++#+############################################ooo+++++++oo+oooo#",
  "#ooo+++#++++++++#+############################################ooo+++++++oo+++oo#",
  "#ooo+++oooooooooo+############################################ooooooooooo++++oo#",
  "#ooo++++oooooooo++############################################o+oooooooo++++ooo#",
  "#oooo+++++++oooo++############################################o+ooo++++++++oooo#",
  "#ooooo+++++o++++o+############################################oo++++++++++ooooo#",
  "#ooooo+++++o++++o+############################################oo+++++++++oooooo#",
  "+oooooo++++oo#o#++############################################oooooo+++++oooooo+",
  ".#oooooo+++ooooo++############################################ooooooo+++oooooo#+",
  ".#oooooo++++o+oo++############################################o+oooo+++oo++ooo++",
  ".+ooooooo+++++++++############################################o+++++++ooo++oo#+.",
  "..+oooooo#++++++++############################################o+++++++ooooooo++.",
  "...ooooooo#+++++++############################################o++++++oooooooo+..",
  "....##ooooo+ooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooo#+...",
  "......####################################################################+.....",
}

-- The four DMG greys, as the palette pass expects them.  Drawing in these
-- exact values is what lets an SGB zone recolour the result: the shader
-- remaps shade indices, so any other grey would land between shades and
-- come out of the colouriser as something nobody chose.
DeckSprite.SHADE = { [0] = 1.0, [1] = 170 / 255, [2] = 85 / 255, [3] = 0.0 }

local CODE = { ["."] = nil, ["+"] = 1, ["o"] = 2, ["#"] = 3 }

local image

-- Where the console's own screen sits inside the art, found by measuring the
-- longest unbroken run of screen pixels rather than being written down
-- twice.  Editing the art above therefore cannot desynchronise the rect the
-- live light dot is drawn into.
local function longestRun(row)
  local best, bestStart, start = 0, 1, nil
  for x = 1, #row do
    if row:sub(x, x) == "#" then
      start = start or x
      if x - start + 1 > best then best, bestStart = x - start + 1, start end
    else
      start = nil
    end
  end
  return best, bestStart
end

-- The screen is the dark run that PERSISTS at the same column across many
-- rows.  Two simpler rules were tried and both picked the wrong thing: the
-- longest run anywhere is the console's bottom edge (68px of solid dark,
-- wider than the screen), and testing a single column picks up the side
-- outline, which spans the whole sprite. Persistence is what actually
-- distinguishes a panel from an edge.
local function findScreen()
  local tally = {}
  for y, row in ipairs(ART) do
    local len, start = longestRun(row)
    if len >= 20 then
      tally[start] = tally[start] or { rows = {}, len = 0 }
      tally[start].rows[#tally[start].rows + 1] = y
      if len > tally[start].len then tally[start].len = len end
    end
  end
  local bestStart, best = nil, nil
  for start, info in pairs(tally) do
    if not best or #info.rows > #best.rows then bestStart, best = start, info end
  end
  if not best then return { x = 0, y = 0, w = 1, h = 1 } end
  local y1, y2 = best.rows[1], best.rows[#best.rows]
  return { x = bestStart - 1, y = y1 - 1, w = best.len, h = y2 - y1 + 1 }
end

DeckSprite.SCREEN = findScreen()

function DeckSprite.image()
  if image ~= nil then return image or nil end
  if not (love and love.image and love.graphics) then return nil end
  local ok, result = pcall(function()
    local data = love.image.newImageData(DeckSprite.W, DeckSprite.H)
    for y = 1, DeckSprite.H do
      local row = ART[y] or ""
      for x = 1, DeckSprite.W do
        local code = CODE[row:sub(x, x)]
        if code then
          local g = DeckSprite.SHADE[code]
          data:setPixel(x - 1, y - 1, g, g, g, 1)
        end
      end
    end
    local img = love.graphics.newImage(data)
    img:setFilter("nearest", "nearest")
    return img
  end)
  image = ok and result or false
  return image or nil
end

return DeckSprite
