-- Shared Networking Setup
if SERVER then
    util.AddNetworkString("MusicPlayer_Broadcast")
    net.Receive("MusicPlayer_Broadcast", function(len, ply)
        local path = net.ReadString()
        net.Start("MusicPlayer_Broadcast")
        net.WriteString(path)
        net.Broadcast()
    end)
    return
end

-- =========================================================================
-- CLIENT SIDE
-- =========================================================================
local playerFrame = nil 
local isHidden = false

-- -----------------------------------------------------------
-- PERSISTENT STATE
-- -----------------------------------------------------------
local currentStream = nil
local currentVolume = 0.5
local currentDuration = 0
local currentSongName = "Stopped."
local lastPath = cookie.GetString("gabes_music_path", "C:/")

-- Load Saved Settings
local customTitle = cookie.GetString("gabe_custom_title", "Player") 
local savedBgPath = cookie.GetString("gabe_bg_path", "")
local savedAlpha = cookie.GetNumber("gabe_bg_alpha", 255)

-- Load Saved Visualizer Color (Default is Blue)
local savedVisColorStr = cookie.GetString("gabe_vis_color", "60 140 220")
local r, g, b = string.match(savedVisColorStr, "(%d+) (%d+) (%d+)")
local customVisColor = Color(tonumber(r) or 60, tonumber(g) or 140, tonumber(b) or 220)

-- 1. THEME DEFINITIONS
local Theme = {
    bg          = Color(25, 25, 30, 255),    
    header      = Color(35, 35, 40, 255),    
    panel_bg    = Color(40, 40, 45, 255),    
    input_bg    = Color(20, 20, 20, 255),    
    text        = Color(230, 230, 230, 255), 
    
    -- UI Colors (Buttons, Tabs - FIXED BLUE)
    accent      = Color(60, 140, 220, 255),  
    
    -- Visualizer Color (CUSTOMIZABLE)
    vis_color   = customVisColor, 
    
    outline     = Color(80, 80, 80, 255),

    -- Indented List Colors
    list_bg     = Color(10, 10, 12, 255),
    list_border = Color(60, 60, 65, 255),
    header_bg   = Color(30, 30, 35, 255),
    
    -- Tab Colors
    tab_active  = Color(60, 140, 220, 255), 
    tab_inactive= Color(35, 35, 40, 255),   
    
    bgMat       = nil,
    bgAlpha     = savedAlpha
}

-- Local Background Image Loader
local function SetBackgroundImage(path)
    if not path or path == "" then 
        Theme.bgMat = nil 
        cookie.Set("gabe_bg_path", "")
        chat.AddText(Color(100, 255, 100), "[System] Background reset.")
        return 
    end

    local loadPath = path

    -- FIX: Source Materials (.vmt) handling
    if string.EndsWith(path, ".vmt") then
        loadPath = string.StripExtension(path)
        if string.StartWith(loadPath, "materials/") then
            loadPath = string.sub(loadPath, 11) 
        elseif string.StartWith(loadPath, "materials\\") then
            loadPath = string.sub(loadPath, 11)
        end
    end

    local mat = Material(loadPath)
    
    if not mat or mat:IsError() or mat:GetName() == "___error" then
        chat.AddText(Color(255, 50, 50), "[System] Invalid material path!")
        return
    end

    Theme.bgMat = mat
    cookie.Set("gabe_bg_path", path) 
    chat.AddText(Color(100, 255, 100), "[System] Background set: " .. string.GetFileFromFilename(path))
end

if savedBgPath ~= "" then SetBackgroundImage(savedBgPath) end

-- =========================================================
-- NETWORKING
-- =========================================================
net.Receive("MusicPlayer_Broadcast", function()
    local path = net.ReadString()
    if not musicplayer then return end
    
    chat.AddText(Theme.accent, "[Music] Global Network Play: ", Color(255,255,255), string.GetFileFromFilename(path))
    
    if GlobalMusicStream then musicplayer.Stop(GlobalMusicStream) end
    
    GlobalMusicStream = musicplayer.Play(path)
    currentStream = GlobalMusicStream
    
    if currentStream then 
        musicplayer.SetVolume(currentStream, currentVolume)
        if musicplayer.SetBassBoost then musicplayer.SetBassBoost(currentStream, bassBoostEnabled) end
        currentDuration = musicplayer.GetLength(currentStream)
        currentSongName = string.GetFileFromFilename(path)
    end
end)

local function InitMusicSystem()
    if IsValid(playerFrame) then 
        playerFrame:SetVisible(true); playerFrame:MakePopup(); isHidden = false; return 
    end

    if not pcall(require, "musicplayer") then
        chat.AddText(Color(255, 50, 50), "ERROR: musicplayer module missing!")
        return
    end

    local function SecondsToTime(seconds)
        if not seconds then return "0:00" end
        seconds = math.floor(seconds)
        return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
    end

    local function CreateStyledEntry(parent)
        local entry = vgui.Create("DTextEntry", parent)
        entry:SetTextColor(Theme.text); entry:SetCursorColor(Theme.text)
        entry.Paint = function(s, w, h)
            draw.RoundedBox(4, 0, 0, w, h, Theme.input_bg) 
            surface.SetDrawColor(Theme.outline); surface.DrawOutlinedRect(0, 0, w, h) 
            s:DrawTextEntryText(Theme.text, Theme.accent, Theme.text)
        end
        return entry
    end
    
    local function ThemeTabs(sheet)
        sheet.Paint = function(s, w, h) draw.RoundedBox(0, 0, 24, w, 1, Theme.outline) end
        for _, item in pairs(sheet:GetItems()) do
            local tab = item.Tab
            tab:SetFont("DermaDefaultBold")
            function tab:ApplySchemeSettings() local w, h = self:GetContentSize(); self:SetSize(w + 10, 24) end
            tab.Paint = function(s, w, h)
                local col = Theme.tab_inactive
                if s:IsActive() then col = Theme.tab_active elseif s:IsHovered() then col = Color(Theme.tab_active.r, Theme.tab_active.g, Theme.tab_active.b, 100) end
                -- Use Fixed Blue Accent for Tabs
                if s:IsActive() then col = Theme.accent end
                draw.RoundedBoxEx(4, 0, 0, w, h - 1, col, true, true, false, false)
            end
            tab.UpdateColours = function(s)
                if s:IsActive() or s:IsHovered() then return s:SetTextColor(Color(255,255,255)) end
                return s:SetTextColor(Theme.text)
            end
        end
    end

    -- -----------------------------------------------------------
    -- MAIN FRAME
    -- -----------------------------------------------------------
    local frame = vgui.Create("DFrame")
    playerFrame = frame
    frame:SetSize(1000, 650); frame:Center(); frame:SetTitle(""); frame:MakePopup()
    frame:ShowCloseButton(false)
    
    frame.Paint = function(s, w, h)
        -- Base Background
        draw.RoundedBox(4, 0, 0, w, h, Theme.bg)
        
        -- Custom Background Image (ASPECT FILL - Looks best for scaling)
        if Theme.bgMat then
            surface.SetDrawColor(255, 255, 255, Theme.bgAlpha)
            surface.SetMaterial(Theme.bgMat)
            
            local texW = Theme.bgMat:Width()
            local texH = Theme.bgMat:Height()
            if texW > 0 and texH > 0 then
                local scale = math.max(w / texW, h / texH) -- Scale to COVER the window
                local drawW = texW * scale
                local drawH = texH * scale
                local drawX = (w - drawW) / 2 -- Center X
                local drawY = (h - drawH) / 2 -- Center Y
                
                -- Scissor to clip overflow
                local sx, sy = s:LocalToScreen(0, 0)
                render.SetScissorRect(sx, sy, sx + w, sy + h, true)
                    surface.DrawTexturedRect(drawX, drawY, drawW, drawH)
                render.SetScissorRect(0, 0, 0, 0, false)
            end
            draw.RoundedBox(4, 0, 0, w, h, Color(0, 0, 0, 100)) 
        end
        
        draw.RoundedBoxEx(4, 0, 0, w, 30, Theme.header, true, true, false, false)
        surface.SetDrawColor(Theme.outline); surface.DrawOutlinedRect(0, 0, w, 30)
        draw.SimpleText(customTitle, "DermaDefaultBold", 10, 8, Theme.text)
    end

    local btnClose = vgui.Create("DButton", frame)
    btnClose:SetPos(970, 0); btnClose:SetSize(30, 30); btnClose:SetText("X"); btnClose:SetTextColor(Color(255,100,100))
    btnClose.Paint = function() end
    btnClose.DoClick = function() frame:Close() end

    local btnMin = vgui.Create("DButton", frame)
    btnMin:SetPos(940, 0); btnMin:SetSize(30, 30); btnMin:SetText("_"); btnMin:SetTextColor(Theme.text)
    btnMin.Paint = function() end
    btnMin.DoClick = function() 
        frame:SetVisible(false); isHidden = true
        chat.AddText(Theme.accent, "[System] ", Color(255,255,255), "Minimized! Hold C + Middle Mouse to restore.")
    end

    local sheet = vgui.Create("DPropertySheet", frame)
    sheet:Dock(FILL); sheet:DockMargin(0, 5, 0, 0)
    
    -- ===========================================================
    -- TAB 1: PLAYER
    -- ===========================================================
    local playerPanel = vgui.Create("DPanel", sheet)
    playerPanel.Paint = function() end
    sheet:AddSheet("Player", playerPanel, "icon16/ipod.png")

    local topPanel = vgui.Create("DPanel", playerPanel)
    topPanel:Dock(TOP); topPanel:SetHeight(40); topPanel:DockMargin(0, 0, 0, 5)
    topPanel.Paint = function(s, w, h) draw.RoundedBox(4, 0, 0, w, h, Theme.panel_bg) end

    local pathEntry = CreateStyledEntry(topPanel)
    pathEntry:Dock(LEFT); pathEntry:SetWidth(600); pathEntry:DockMargin(5, 5, 5, 5); pathEntry:SetText(lastPath)

    local btnScan = vgui.Create("DButton", topPanel)
    btnScan:Dock(FILL); btnScan:DockMargin(5, 5, 5, 5); btnScan:SetText("SCAN"); btnScan:SetTextColor(Theme.text)
    btnScan.Paint = function(s, w, h) 
        draw.RoundedBox(4, 0, 0, w, h, Theme.accent) -- Uses FIXED BLUE
        surface.SetDrawColor(Theme.outline); surface.DrawOutlinedRect(0,0,w,h)
    end

    local split = vgui.Create("DHorizontalDivider", playerPanel); split:Dock(FILL); split:SetLeftWidth(400)
    local listView = vgui.Create("DListView", split)
    listView:SetMultiSelect(false); listView:AddColumn("Name"); listView:AddColumn("Type"):SetFixedWidth(50)
    
    for _, col in pairs(listView.Columns) do
        col.Header.Paint = function(s, w, h)
            draw.RoundedBox(0, 0, 0, w, h, Theme.header_bg)
            surface.SetDrawColor(Theme.list_border); surface.DrawOutlinedRect(0, 0, w, h)
        end
        col.Header:SetTextColor(Theme.text)
    end

    listView.Paint = function(s, w, h)
        draw.RoundedBox(0, 0, 0, w, h, Theme.list_bg)
        surface.SetDrawColor(Theme.list_border); surface.DrawOutlinedRect(0, 0, w, h)
    end
    
    local function FixLineColors()
        for _, line in pairs(listView:GetLines()) do
            line.Paint = function(s, w, h)
                if s:IsSelected() then draw.RoundedBox(0, 0, 0, w, h, Theme.accent) -- Uses FIXED BLUE
                elseif s:IsHovered() then draw.RoundedBox(0, 0, 0, w, h, Color(Theme.accent.r, Theme.accent.g, Theme.accent.b, 30)) end
            end
            for _, col in pairs(line.Columns) do col:SetTextColor(Theme.text) end
        end
    end

    split:SetLeft(listView)
    local rightPanel = vgui.Create("DPanel", split)
    rightPanel.Paint = function(s, w, h) draw.RoundedBox(0, 0, 0, w, h, Color(0, 0, 0, 50)) end
    split:SetRight(rightPanel)

    local visualizer = vgui.Create("DPanel", rightPanel)
    visualizer:Dock(TOP); visualizer:DockMargin(10, 20, 10, 0); visualizer:SetHeight(80)
    visualizer.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, Color(0,0,0,150))
        surface.SetDrawColor(Theme.outline); surface.DrawOutlinedRect(0,0,w,h)
        
        if currentStream and musicplayer.GetFFT then
            local fftData = musicplayer.GetFFT(currentStream, 64) 
            if fftData and #fftData > 0 then
                local barWidth = w / #fftData
                local spacing = 1
                
                -- USE CUSTOMIZABLE COLOR HERE
                surface.SetDrawColor(Theme.vis_color)
                
                -- Dynamic Multiplier: High Volume = Taller Bars
                local volMultiplier = math.max(currentVolume * 10, 1)

                for i = 1, #fftData do
                    local val = math.Clamp(fftData[i] * volMultiplier, 0, 1)
                    local barHeight = val * h
                    surface.DrawRect((i-1) * barWidth, h - barHeight, barWidth - spacing, barHeight)
                end
            end
        end
        
        local txt = currentSongName
        surface.SetFont("DermaLarge")
        local tw, th = surface.GetTextSize(txt)
        local x = (w - tw) / 2
        if tw > w then x = w - ((CurTime() * 100) % (tw + w)) end
        draw.SimpleText(txt, "DermaLarge", x+2, (h/2)+2, Color(0,0,0,200), TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        draw.SimpleText(txt, "DermaLarge", x, h/2, Theme.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
    end

    local seekContainer = vgui.Create("DPanel", rightPanel); seekContainer:Dock(TOP); seekContainer:SetHeight(70); seekContainer:DockMargin(20, 10, 20, 0); seekContainer.Paint = function() end
    local lblTime = vgui.Create("DLabel", seekContainer); lblTime:Dock(TOP); lblTime:SetText("0:00 / 0:00"); lblTime:SetContentAlignment(5); lblTime:SetTextColor(Theme.text)
    local seekSlider = vgui.Create("DSlider", seekContainer); seekSlider:Dock(TOP); seekSlider:SetHeight(30); seekSlider:SetSlideX(0); seekSlider:SetLockY(0.5)
    seekSlider.Paint = function(s, w, h) 
        draw.RoundedBox(2, 0, h/2 - 2, w, 4, Color(0,0,0,255)) 
        draw.RoundedBox(2, 0, h/2 - 2, w * s:GetSlideX(), 4, Theme.accent) -- Fixed Blue
    end
    seekSlider.Knob.Paint = function(s, w, h) draw.RoundedBox(8, 0, 0, w, h, Theme.text) end
    seekSlider.OnValueChanged = function(self, val) if self:IsEditing() and currentDuration > 0 then lblTime:SetText(SecondsToTime(val * currentDuration) .. " / " .. SecondsToTime(currentDuration)) end end
    seekSlider.Knob.OnMouseReleased = function(self, m) if currentStream then musicplayer.SetPos(currentStream, seekSlider:GetSlideX() * currentDuration) end self:MouseCapture(false) return DButton.OnMouseReleased(self, m) end

    -- Custom Slider
    local function CreateCustomSlider(parent, label, min, max, default, onSlide)
        local panel = vgui.Create("DPanel", parent)
        panel:Dock(TOP); panel:SetHeight(50); panel:DockMargin(10, 5, 10, 5); panel.Paint = function() end
        local topBar = vgui.Create("DPanel", panel); topBar:Dock(TOP); topBar:SetHeight(20); topBar.Paint = function() end
        local lbl = vgui.Create("DLabel", topBar); lbl:Dock(LEFT); lbl:SetWidth(200); lbl:SetText(label); lbl:SetTextColor(Theme.text); lbl:SetFont("DermaDefaultBold")
        
        local valLbl = vgui.Create("DLabel", topBar)
        valLbl:Dock(RIGHT); valLbl:SetWidth(50); valLbl:SetText(string.format("%.2f", default))
        valLbl:SetTextColor(Theme.accent); valLbl:SetFont("DermaDefaultBold"); valLbl:SetContentAlignment(6)
        valLbl:SetMouseInputEnabled(true); valLbl:SetCursor("hand"); valLbl:SetTooltip("Double Click to Edit")

        local slider = vgui.Create("DSlider", panel)
        slider:Dock(FILL); slider:DockMargin(0, 5, 0, 0); slider:SetLockY(0.5)
        slider:SetSlideX((default - min) / (max - min))
        
        local function UpdateValue(num)
             num = math.Clamp(num, min, max)
             local fraction = (num - min) / (max - min)
             slider:SetSlideX(fraction)
             valLbl:SetText(string.format("%.2f", num))
             onSlide(num)
        end

        valLbl.DoDoubleClick = function()
            local edit = vgui.Create("DTextEntry", topBar)
            edit:SetPos(valLbl:GetPos()); edit:SetSize(valLbl:GetSize()); edit:SetText(valLbl:GetText())
            edit:SetFont("DermaDefaultBold"); edit:RequestFocus(); edit:SelectAllText()
            local function Submit()
                if not IsValid(edit) then return end
                local num = tonumber(edit:GetText())
                if num then UpdateValue(num) end
                edit:Remove(); valLbl:SetVisible(true)
            end
            edit.OnEnter = Submit; edit.OnLoseFocus = Submit; valLbl:SetVisible(false) 
        end

        slider.Paint = function(s, w, h) 
            draw.RoundedBox(2, 0, h/2 - 2, w, 4, Color(0, 0, 0, 255))
            draw.RoundedBox(2, 0, h/2 - 2, w * s:GetSlideX(), 4, Theme.accent) -- Fixed Blue
        end
        slider.Knob.Paint = function(s, w, h) draw.RoundedBox(8, 0, 0, w, h, Theme.text) end
        slider.OnValueChanged = function(s) 
            local finalVal = min + (s:GetSlideX() * (max - min))
            valLbl:SetText(string.format("%.2f", finalVal))
            onSlide(finalVal) 
        end
        return slider
    end

    local btnPlay = vgui.Create("DButton", rightPanel); btnPlay:Dock(TOP); btnPlay:DockMargin(20, 10, 20, 10); btnPlay:SetHeight(40); btnPlay:SetText("PLAY SELECTED"); btnPlay:SetTextColor(Color(255,255,255))
    btnPlay:SetFont("DermaDefaultBold")
    btnPlay.Paint = function(s, w, h) 
        draw.RoundedBox(4, 0, 0, w, h, Theme.accent) -- Fixed Blue
        surface.SetDrawColor(Theme.outline); surface.DrawOutlinedRect(0,0,w,h)
    end
    btnPlay.DoClick = function() if frame.SelectedFile then PlayFile(frame.SelectedFile) end end

    local btnStop = vgui.Create("DButton", rightPanel); btnStop:Dock(TOP); btnStop:DockMargin(20, 0, 20, 20); btnStop:SetHeight(30); btnStop:SetText("STOP"); btnStop:SetTextColor(Color(255,255,255))
    btnStop.Paint = function(s,w,h) draw.RoundedBox(4,0,0,w,h, Color(180, 50, 50)) end
    
    btnStop.DoClick = function() 
        if currentStream then 
            musicplayer.Stop(currentStream)
            currentStream = nil
            currentSongName = "Stopped."
            seekSlider:SetSlideX(0)
        end 
    end

    CreateCustomSlider(rightPanel, "Volume", 0, 1, 0.5, function(val) currentVolume = val; if currentStream then musicplayer.SetVolume(currentStream, val) end end)
    CreateCustomSlider(rightPanel, "Pitch / Speed", 0.5, 2.0, 1.0, function(val) if currentStream then musicplayer.SetPitch(currentStream, val) end end)

    function PlayFile(path)
        if currentStream then musicplayer.Stop(currentStream) end
        GlobalMusicStream = musicplayer.Play(path)
        currentStream = GlobalMusicStream
        if currentStream then
            currentDuration = musicplayer.GetLength(currentStream)
            musicplayer.SetVolume(currentStream, currentVolume)
            if musicplayer.SetBassBoost then musicplayer.SetBassBoost(currentStream, bassBoostEnabled) end
            currentSongName = string.GetFileFromFilename(path) 
            lblTime:SetText("0:00 / " .. SecondsToTime(currentDuration))
        else
            currentSongName = "Error: Failed to Load"
        end
    end

    local function ScanAndPopulate(path)
        if not string.EndsWith(path, "/") and not string.EndsWith(path, "\\") then path = path .. "/" end
        pathEntry:SetText(path); lastPath = path; cookie.Set("gabes_music_path", path)
        local data = musicplayer.ScanDir(path)
        if not data then return end
        listView:Clear()
        if #path > 4 then
            local line = listView:AddLine(".. (Go Up)", "DIR"); line.IsUp = true; line.Path = string.GetPathFromFilename(string.Left(path, #path - 1))
        end
        if data.folders then
            for _, folderName in ipairs(data.folders) do
                local line = listView:AddLine(folderName, "DIR"); line.Path = path .. folderName; line.IsFolder = true
            end
        end
        if data.files then
            for _, fileName in ipairs(data.files) do
                local line = listView:AddLine(fileName, "FILE"); line.Path = path .. fileName; line.IsFile = true
            end
        end
        FixLineColors()
    end
    
    listView.OnRowSelected = function(lst, idx, pnl) if pnl.IsFile then frame.SelectedFile = pnl.Path end end
    listView.DoDoubleClick = function(lst, idx, pnl)
        if pnl.IsUp or pnl.IsFolder then ScanAndPopulate(pnl.Path) elseif pnl.IsFile then frame.SelectedFile = pnl.Path; PlayFile(pnl.Path) end
    end
    listView.OnRowRightClick = function(lst, idx, pnl)
        if pnl.IsFile then
            frame.SelectedFile = pnl.Path
            local menu = DermaMenu()
            menu:AddOption("Play Locally", function() PlayFile(pnl.Path) end):SetIcon("icon16/sound.png")
            menu:AddOption("Play for Everyone", function() net.Start("MusicPlayer_Broadcast"); net.WriteString(pnl.Path); net.SendToServer(); chat.AddText(Color(100, 255, 100), "Request sent.") end):SetIcon("icon16/group.png")
            menu:Open()
        end
    end

    btnScan.DoClick = function() ScanAndPopulate(pathEntry:GetText()) end
    
    -- ===========================================================
    -- TAB 2: SETTINGS (REFACTORED SECTION)
    -- ===========================================================
    local settingsPanel = vgui.Create("DPanel", sheet)
    settingsPanel.Paint = function(s, w, h) draw.RoundedBox(0, 0, 0, w, h, Theme.panel_bg) end
    sheet:AddSheet("Settings", settingsPanel, "icon16/palette.png")
    
    local titlePanel = vgui.Create("DPanel", settingsPanel); titlePanel:Dock(TOP); titlePanel:SetHeight(50); titlePanel:DockMargin(10,10,10,0); titlePanel.Paint = function() end
    local lblTitle = vgui.Create("DLabel", titlePanel); lblTitle:Dock(TOP); lblTitle:SetText("Window Title Name:"); lblTitle:SetTextColor(Theme.text); lblTitle:SetFont("DermaDefaultBold")
    local txtTitle = CreateStyledEntry(titlePanel); txtTitle:Dock(LEFT); txtTitle:SetWidth(400); txtTitle:SetText(customTitle)
    local btnSetTitle = vgui.Create("DButton", titlePanel); btnSetTitle:Dock(LEFT); btnSetTitle:SetText("Set Title"); btnSetTitle:SetWidth(100); btnSetTitle:DockMargin(5,0,0,0)
    btnSetTitle.DoClick = function() customTitle = txtTitle:GetText(); cookie.Set("gabe_custom_title", customTitle); frame:Close(); InitMusicSystem() end

    -- Main Appearance Panel Container
    local appearancePanel = vgui.Create("DPanel", settingsPanel)
    appearancePanel:Dock(TOP)
    appearancePanel:SetHeight(220) -- INCREASED HEIGHT (Fixes "squished" frame)
    appearancePanel:DockMargin(10,10,10,0)
    appearancePanel.Paint = function() end
    
    -- -----------------------------------------------------------
    -- LEFT COLUMN: Visualizer Color
    -- -----------------------------------------------------------
    local leftCol = vgui.Create("DPanel", appearancePanel)
    leftCol:Dock(LEFT)
    leftCol:SetWidth(250)
    leftCol:DockMargin(0, 0, 10, 0)
    leftCol.Paint = function() end

    -- Label on Top
    local lblMixer = vgui.Create("DLabel", leftCol)
    lblMixer:Dock(TOP)
    lblMixer:SetText("Visualizer Color:")
    lblMixer:SetTextColor(Theme.text)
    lblMixer:SetFont("DermaDefaultBold")
    lblMixer:DockMargin(0, 0, 0, 5)

    -- Mixer Below Label (Fills rest of Left Column)
    local mixer = vgui.Create("DColorMixer", leftCol)
    mixer:Dock(FILL) 
    mixer:SetPalette(false); mixer:SetAlphaBar(false); mixer:SetWangs(false)
    mixer:SetColor(Theme.vis_color)
    mixer.ValueChanged = function(s, col)
        Theme.vis_color = col
        cookie.Set("gabe_vis_color", string.format("%d %d %d", col.r, col.g, col.b))
    end

    -- -----------------------------------------------------------
    -- RIGHT COLUMN: Background Opacity
    -- -----------------------------------------------------------
    local rightCol = vgui.Create("DPanel", appearancePanel)
    rightCol:Dock(FILL)
    rightCol.Paint = function() end

    -- Label on Top (Not overlapping slider)
    local lblAlpha = vgui.Create("DLabel", rightCol)
    lblAlpha:Dock(TOP)
    lblAlpha:SetText("")
    lblAlpha:SetTextColor(Theme.text)
    lblAlpha:SetFont("DermaDefaultBold")
    lblAlpha:DockMargin(0, 0, 0, 5)

    -- Slider Below Label
    local alphaSlider = vgui.Create("DNumSlider", rightCol)
    alphaSlider:Dock(TOP)
    alphaSlider:SetText("") -- Hide internal text so it doesn't overlap/sit in front
    alphaSlider:SetMinMax(0, 255)
    alphaSlider:SetDecimals(0)
    alphaSlider:SetValue(Theme.bgAlpha)
    
    -- Style the label inside DNumSlider just in case, though we set text to ""
    alphaSlider.Label:SetTextColor(Theme.text) 
    
    alphaSlider.OnValueChanged = function(s, val)
        Theme.bgAlpha = val
        cookie.Set("gabe_bg_alpha", val)
    end

    -- Reset Button (Moved to be clearly separated below settings)
    local resetPanel = vgui.Create("DPanel", settingsPanel)
    resetPanel:Dock(BOTTOM); resetPanel:SetHeight(40); resetPanel:DockMargin(10, 5, 10, 10); resetPanel.Paint = function() end
    local btnReset = vgui.Create("DButton", resetPanel)
    btnReset:Dock(RIGHT); btnReset:SetText("Reset Background"); btnReset:SetWidth(150); btnReset:SetTextColor(Color(255, 80, 80))
    btnReset.DoClick = function() SetBackgroundImage("") end

    -- File Browser
    local bgPanel = vgui.Create("DPanel", settingsPanel); bgPanel:Dock(FILL); bgPanel:DockMargin(10,10,10,5); bgPanel.Paint = function() end
    local lblBg = vgui.Create("DLabel", bgPanel); lblBg:Dock(TOP); lblBg:SetText("Select Background Image (Local File):"); lblBg:SetTextColor(Theme.text); lblBg:SetFont("DermaDefaultBold")
    
    local bgTree = vgui.Create("DTree", bgPanel)
    bgTree:Dock(FILL); bgTree:DockMargin(0, 5, 0, 0)
    bgTree.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, Theme.list_bg); surface.SetDrawColor(Theme.list_border); surface.DrawOutlinedRect(0, 0, w, h)
    end

    local function PopulateNode(node, folder)
        local files, dirs = file.Find(folder .. "/*", "GAME")
        for _, dir in ipairs(dirs) do
            local n = node:AddNode(dir); n.Folder = folder .. "/" .. dir
            n.DoClick = function(self) if not self.Populated then PopulateNode(self, self.Folder); self.Populated = true end end
        end
        for _, f in ipairs(files) do
            if string.EndsWith(f, ".png") or string.EndsWith(f, ".jpg") or string.EndsWith(f, ".vmt") then
                local n = node:AddNode(f); n:SetIcon("icon16/picture.png"); n.Path = folder .. "/" .. f
                n.DoClick = function() SetBackgroundImage(n.Path) end
            end
        end
    end

    local rootData = bgTree:AddNode("data"); rootData.Folder = "data"
    rootData.DoClick = function(s) if not s.Populated then PopulateNode(s, "data") s.Populated=true end end
    local rootMats = bgTree:AddNode("materials"); rootMats.Folder = "materials"
    rootMats.DoClick = function(s) if not s.Populated then PopulateNode(s, "materials") s.Populated=true end end

    ThemeTabs(sheet)
    btnScan:DoClick()
    
    local timerName = "MusicPlayerUpdateUI"
    timer.Create(timerName, 0.05, 0, function() 
        if not IsValid(frame) then timer.Remove(timerName) return end
        if currentStream and not seekSlider:IsEditing() then
            local pos = musicplayer.GetPos(currentStream)
            if pos and currentDuration > 0 then seekSlider:SetSlideX(pos / currentDuration); lblTime:SetText(SecondsToTime(pos) .. " / " .. SecondsToTime(currentDuration)) end
        end
    end)
end

hook.Add("Think", "GabesPlayerRestore", function()
    if isHidden and IsValid(playerFrame) then
        if input.IsKeyDown(KEY_C) and input.IsMouseDown(MOUSE_MIDDLE) then
             playerFrame:SetVisible(true); playerFrame:MakePopup(); isHidden = false
             chat.AddText(Color(100, 255, 100), "[System] Restored.")
        end
    end
end)

concommand.Add("open_player", InitMusicSystem)

hook.Add("OnPlayerChat", "GabesPlayerChatCommand", function(ply, text)
    if ply == LocalPlayer() and string.lower(text) == "!player" then InitMusicSystem(); return true end
end)

hook.Add("InitPostEntity", "GabesPlayerWelcome", function()
    timer.Simple(2, function() 
        chat.AddText(Color(60, 140, 220), "[Player] ", Color(255, 255, 255), "Welcome! Type !player or use 'open_player' to listen to music.")
    end)
end)