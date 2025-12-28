-- =========================================================
-- IMPORTANT: RENAME THIS FILE
-- =========================================================
-- Rename from 'sh_music_player.lua' to 'gabes_player.lua'
-- The 'sh_' prefix causes 'Missing Type and Base' error.

-- Shared Networking Setup
if SERVER then
    util.AddNetworkString("MusicPlayer_Broadcast") -- Simple play
    util.AddNetworkString("MusicPlayer_Control")   -- Sync controls (Stop, Volume, Pitch, Seek)
    util.AddNetworkString("MusicPlayer_Open")      -- Open command
    util.AddNetworkString("MusicPlayer_Queue")     -- Queue management
    
    -- Simple Play
    net.Receive("MusicPlayer_Broadcast", function(len, ply)
        if not ply:IsAdmin() then return end -- [SECURED] Only Admins can play global
        
        local path = net.ReadString()
        net.Start("MusicPlayer_Broadcast")
        net.WriteString(path)
        net.Broadcast()
    end)

    -- Control Sync (Volume, Pitch, Seek, Stop)
    net.Receive("MusicPlayer_Control", function(len, ply)
        if not ply:IsAdmin() then return end -- [SECURED] Only Admins can control global
        
        local type = net.ReadString() -- "update", "seek", or "stop"
        local val1 = net.ReadFloat()  -- volume or seek time
        local val2 = net.ReadFloat()  -- pitch
        
        net.Start("MusicPlayer_Control")
        net.WriteString(type)
        net.WriteFloat(val1)
        net.WriteFloat(val2)
        net.Broadcast()
    end)

    -- Queue Management (Add, Remove, Clear, Load)
    net.Receive("MusicPlayer_Queue", function(len, ply)
        if not ply:IsAdmin() then return end -- [SECURED] Only Admins can manage queue
        
        local action = net.ReadString()
        
        if action == "add" then
            local path = net.ReadString()
            local name = net.ReadString()
            
            net.Start("MusicPlayer_Queue")
            net.WriteString("add")
            net.WriteString(path)
            net.WriteString(name)
            net.Broadcast()
            
        elseif action == "remove" then
            local index = net.ReadUInt(16)
            
            net.Start("MusicPlayer_Queue")
            net.WriteString("remove")
            net.WriteUInt(index, 16)
            net.Broadcast()
            
        elseif action == "clear" then
            net.Start("MusicPlayer_Queue")
            net.WriteString("clear")
            net.Broadcast()
            
        elseif action == "load_collection" then
            local colName = net.ReadString()
            
            net.Start("MusicPlayer_Queue")
            net.WriteString("load_collection")
            net.WriteString(colName)
            net.Broadcast()
        end
    end)

    -- [FIX] SERVER SIDE CHAT COMMAND (Hides message from all players)
    hook.Add("PlayerSay", "GabesPlayerChatCommand", function(ply, text)
        local cmd = string.lower(text)
        if cmd == "/player" or cmd == "!player" then
            net.Start("MusicPlayer_Open")
            net.Send(ply)
            return "" -- This prevents message from showing in chat
        end
    end)

    return
end

-- =========================================================================
-- CLIENT SIDE
-- =========================================================================
local playerFrame = nil 
local isHidden = false

-- [FIX] CHAT MESSAGE HIDING FOR LOCAL PLAYER
hook.Add("OnPlayerChat", "HideMusicPlayerCommand", function(ply, text, team, isDead)
    if ply == LocalPlayer() then
        local cmd = string.lower(text)
        if cmd == "/player" or cmd == "!player" then
            return true -- Hide from local chat
        end
    end
end)

-- -----------------------------------------------------------
-- PERSISTENT STATE & LOGIC
-- -----------------------------------------------------------
local currentStream = nil
local currentVolume = 0.5
local currentDuration = 0
local currentSongName = "Stopped."
local lastPath = cookie.GetString("gabes_music_path", "C:/")

-- Sync State
local isNetworkedPlayback = false 
local amITheDJ = false 

-- ACTIVE QUEUE (The temporary list of songs currently playing)
local ActiveQueue = util.JSONToTable(cookie.GetString("gabe_active_queue", "[]")) or {}
local currentQueueIndex = 0 
local isLooping = false -- Loop track feature

-- COLLECTIONS (Saved Playlists)
local SavedCollections = util.JSONToTable(cookie.GetString("gabe_saved_collections", "{}")) or {}

-- SHORTCUTS (Sidebar) - Now supports Files and Folders
local folderShortcuts = util.JSONToTable(cookie.GetString("gabe_folder_shortcuts", "[]")) or {}

-- Load Saved Settings
local customTitle = cookie.GetString("gabe_custom_title", "Player") 
local savedBgPath = cookie.GetString("gabe_bg_path", "")
local savedAlpha = cookie.GetNumber("gabe_bg_alpha", 255)
local isLocalMode = cookie.GetNumber("gabe_local_mode", 0) == 1 

local function SaveActiveQueue()
    cookie.Set("gabe_active_queue", util.TableToJSON(ActiveQueue))
end

local function SaveCollections()
    cookie.Set("gabe_saved_collections", util.TableToJSON(SavedCollections))
end

local function SaveShortcuts()
    cookie.Set("gabe_folder_shortcuts", util.TableToJSON(folderShortcuts))
end

-- Load Saved Visualizer Color
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
    
    -- UI Colors
    accent      = Color(60, 140, 220, 255),  
    
    -- Visualizer Color
    vis_color   = customVisColor, 
    
    outline     = Color(80, 80, 80, 255),

    -- List Colors
    list_bg     = Color(10, 10, 12, 255),
    list_border = Color(60, 60, 65, 255),
    header_bg   = Color(30, 30, 35, 255),
    
    -- Folder/File Colors
    folder_text = Color(255, 200, 50, 255), 
    file_text   = Color(230, 230, 230, 255), 
    
    -- Tab Colors
    tab_active  = Color(60, 140, 220, 255), 
    tab_inactive= Color(35, 35, 40, 255),    
    
    bgMat       = nil,
    bgAlpha     = savedAlpha
}

local function SetBackgroundImage(path)
    if not path or path == "" then 
        Theme.bgMat = nil 
        cookie.Set("gabe_bg_path", "")
        notification.AddLegacy("Background reset.", NOTIFY_GENERIC, 3)
        return 
    end

    local loadPath = path
    if string.EndsWith(path, ".vmt") then
        loadPath = string.StripExtension(path)
        if string.StartWith(loadPath, "materials/") then loadPath = string.sub(loadPath, 11) end
    end

    local mat = Material(loadPath)
    if not mat or mat:IsError() or mat:GetName() == "___error" then
        notification.AddLegacy("Invalid material path!", NOTIFY_ERROR, 4)
        return
    end

    Theme.bgMat = mat
    cookie.Set("gabe_bg_path", path) 
    notification.AddLegacy("Background set: " .. string.GetFileFromFilename(path), NOTIFY_GENERIC, 3)
end

if savedBgPath ~= "" then SetBackgroundImage(savedBgPath) end

-- =========================================================
-- NETWORKING (SYNC LOGIC)
-- =========================================================

net.Receive("MusicPlayer_Broadcast", function()
    local path = net.ReadString()
    if not musicplayer then return end
    
    notification.AddLegacy("Global Play: " .. string.GetFileFromFilename(path), NOTIFY_GENERIC, 4)
    
    if GlobalMusicStream then musicplayer.Stop(GlobalMusicStream) end
    
    GlobalMusicStream = musicplayer.Play(path)
    currentStream = GlobalMusicStream
    
    isNetworkedPlayback = true 
    
    if currentStream then 
        musicplayer.SetVolume(currentStream, currentVolume)
        currentDuration = musicplayer.GetLength(currentStream)
        currentSongName = "[NET] " .. string.GetFileFromFilename(path)
        
        if IsValid(playerFrame) and IsValid(playerFrame.btnStop) then
            playerFrame.btnStop:SetText("STOP (GLOBAL)")
            playerFrame.btnStop.Paint = function(s,w,h) draw.RoundedBox(4,0,0,w,h, Color(220, 50, 50)) end 
        end
    end
end)

net.Receive("MusicPlayer_Control", function()
    local type = net.ReadString()
    local val1 = net.ReadFloat()
    local val2 = net.ReadFloat()

    if type == "stop" then
        if currentStream then musicplayer.Stop(currentStream) end
        currentStream = nil
        currentSongName = "Stopped by Host."
        isNetworkedPlayback = false
        amITheDJ = false 
        
        if IsValid(playerFrame) and IsValid(playerFrame.btnStop) then
            playerFrame.btnStop:SetText("STOP")
            playerFrame.btnStop.Paint = function(s,w,h) draw.RoundedBox(4,0,0,w,h, Color(180, 50, 50)) end 
        end
        
    elseif type == "update" then
        currentVolume = val1
        if currentStream then
            musicplayer.SetVolume(currentStream, currentVolume)
            musicplayer.SetPitch(currentStream, val2)
        end
    elseif type == "seek" then
        if currentStream then
            musicplayer.SetPos(currentStream, val1)
        end
    end
end)

-- [FIX] NETWORKED QUEUE MANAGEMENT
net.Receive("MusicPlayer_Queue", function()
    local action = net.ReadString()
    
    if action == "add" then
        local path = net.ReadString()
        local name = net.ReadString()
        
        table.insert(ActiveQueue, {path = path, name = name})
        SaveActiveQueue()
        
        if IsValid(playerFrame) and playerFrame.RefreshQueueList then
            playerFrame.RefreshQueueList()
        end
        
    elseif action == "remove" then
        local index = net.ReadUInt(16)
        
        if ActiveQueue[index] then
            table.remove(ActiveQueue, index)
            SaveActiveQueue()
            
            if IsValid(playerFrame) and playerFrame.RefreshQueueList then
                playerFrame.RefreshQueueList()
            end
        end
        
    elseif action == "clear" then
        ActiveQueue = {}
        SaveActiveQueue()
        
        if IsValid(playerFrame) and playerFrame.RefreshQueueList then
            playerFrame.RefreshQueueList()
        end
        
    elseif action == "load_collection" then
        local colName = net.ReadString()
        local songs = SavedCollections[colName] or {}
        
        for _, s in ipairs(songs) do
            table.insert(ActiveQueue, s)
        end
        
        SaveActiveQueue()
        
        if IsValid(playerFrame) and playerFrame.RefreshQueueList then
            playerFrame.RefreshQueueList()
        end
    end
end)

-- =========================================================
-- MAIN SYSTEM INITIALIZATION
-- =========================================================

local function InitMusicSystem()
    if IsValid(playerFrame) then 
        playerFrame:SetVisible(true); playerFrame:MakePopup(); isHidden = false; return 
    end

    if not pcall(require, "musicplayer") then
        notification.AddLegacy("ERROR: musicplayer module missing!", NOTIFY_ERROR, 5)
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
                if s:IsActive() then col = Theme.accent elseif s:IsHovered() then col = Color(Theme.accent.r, Theme.accent.g, Theme.accent.b, 100) end
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
    -- [FEATURE] RESIZABLE
    frame:SetSizable(true)
    frame:SetMinWidth(900)
    frame:SetMinHeight(600)
    
    frame.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, Theme.bg)
        if Theme.bgMat then
            surface.SetDrawColor(255, 255, 255, Theme.bgAlpha)
            surface.SetMaterial(Theme.bgMat)
            local texW = Theme.bgMat:Width(); local texH = Theme.bgMat:Height()
            if texW > 0 and texH > 0 then
                local scale = math.max(w / texW, h / texH)
                local drawW = texW * scale; local drawH = texH * scale
                local drawX = (w - drawW) / 2; local drawY = (h - drawH) / 2
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
    -- Update Close Button Pos on Resize
    frame.OnSizeChanged = function(s, w, h)
        btnClose:SetPos(w - 30, 0)
        if IsValid(s.btnMin) then s.btnMin:SetPos(w - 60, 0) end
    end
    btnClose.Paint = function() end
    btnClose.DoClick = function() frame:Close() end

    local btnMin = vgui.Create("DButton", frame)
    frame.btnMin = btnMin
    btnMin:SetPos(940, 0); btnMin:SetSize(30, 30); btnMin:SetText("_"); btnMin:SetTextColor(Theme.text)
    btnMin.Paint = function() end
    btnMin.DoClick = function() 
        frame:SetVisible(false); isHidden = true
        notification.AddLegacy("Minimized! Hold C + RMB", NOTIFY_HINT, 5)
    end

    local sheet = vgui.Create("DPropertySheet", frame)
    sheet:Dock(FILL); sheet:DockMargin(0, 5, 0, 0)
    
    -- ===========================================================
    -- TAB 1: LIBRARY
    -- ===========================================================
    local playerPanel = vgui.Create("DPanel", sheet)
    playerPanel.Paint = function() end
    sheet:AddSheet("Library", playerPanel, "icon16/folder_explore.png")

    -- Top bar (Scan/Pin/Path/Search)
    local topPanel = vgui.Create("DPanel", playerPanel)
    topPanel:Dock(TOP); topPanel:SetHeight(40); topPanel:DockMargin(0, 0, 0, 5)
    topPanel.Paint = function(s, w, h) draw.RoundedBox(4, 0, 0, w, h, Theme.panel_bg) end

    -- PIN BUTTON (Star)
    local btnPinFolder = vgui.Create("DButton", topPanel)
    btnPinFolder:Dock(LEFT); btnPinFolder:SetWidth(30); btnPinFolder:DockMargin(0, 5, 5, 5) 
    btnPinFolder:SetText(""); btnPinFolder:SetIcon("icon16/star.png")
    btnPinFolder:SetTooltip("Pin current folder to Sidebar")
    btnPinFolder.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, Theme.header)
        surface.SetDrawColor(Theme.outline); surface.DrawOutlinedRect(0,0,w,h)
    end

    -- SCAN BUTTON
    local btnScan = vgui.Create("DButton", topPanel)
    btnScan:Dock(RIGHT); btnScan:SetWidth(80); btnScan:DockMargin(5, 5, 5, 5); btnScan:SetText("SCAN"); btnScan:SetTextColor(Theme.text)
    btnScan.Paint = function(s, w, h) 
        draw.RoundedBox(4, 0, 0, w, h, Theme.accent)
        surface.SetDrawColor(Theme.outline); surface.DrawOutlinedRect(0,0,w,h)
    end

    -- [FEATURE] SEARCH BAR
    local searchEntry = CreateStyledEntry(topPanel)
    searchEntry:Dock(RIGHT); searchEntry:SetWidth(200); searchEntry:DockMargin(5, 5, 5, 5)
    searchEntry:SetPlaceholderText("Search in folder...")

    -- PATH ENTRY
    local pathEntry = CreateStyledEntry(topPanel)
    pathEntry:Dock(FILL); pathEntry:DockMargin(5, 5, 5, 5); pathEntry:SetText(lastPath)

    -- MAIN SPLIT: [Browser Area (Left)] | [Controls (Right)]
    local mainSplit = vgui.Create("DHorizontalDivider", playerPanel)
    mainSplit:Dock(FILL)
    mainSplit:SetLeftWidth(600) 
    
    -- BROWSER AREA CONTAINER (Holds Shortcuts + File List)
    local browserArea = vgui.Create("DPanel")
    browserArea.Paint = function() end
    
    -- SIDEBAR SPLIT: [Shortcuts (Left)] | [File List (Right)]
    local browserSplit = vgui.Create("DHorizontalDivider", browserArea)
    browserSplit:Dock(FILL)
    browserSplit:SetLeftWidth(150) 

    -- 1. SHORTCUTS SIDEBAR
    local shortcutList = vgui.Create("DListView")
    shortcutList:SetMultiSelect(false)
    shortcutList:AddColumn("Quick Access")
    shortcutList.Paint = function(s, w, h)
        draw.RoundedBox(0, 0, 0, w, h, Color(30, 30, 35, 255)) 
        surface.SetDrawColor(Theme.list_border); surface.DrawOutlinedRect(0, 0, w, h)
    end
    shortcutList.Columns[1].Header:SetTextColor(Theme.text)
    
    -- 2. FILE LIST
    local listView = vgui.Create("DListView")
    listView:SetMultiSelect(false); listView:AddColumn("Name"); listView:AddColumn("Type"):SetFixedWidth(50)
    listView.Paint = function(s, w, h)
        draw.RoundedBox(0, 0, 0, w, h, Theme.list_bg)
        surface.SetDrawColor(Theme.list_border); surface.DrawOutlinedRect(0, 0, w, h)
    end
    for _, col in pairs(listView.Columns) do
        col.Header.Paint = function(s, w, h)
            draw.RoundedBox(0, 0, 0, w, h, Theme.header_bg)
            surface.SetDrawColor(Theme.list_border); surface.DrawOutlinedRect(0, 0, w, h)
        end
        col.Header:SetTextColor(Theme.text)
    end

    browserSplit:SetLeft(shortcutList)
    browserSplit:SetRight(listView)
    mainSplit:SetLeft(browserArea)
    
    -- 3. CONTROLS AREA
    local rightPanel = vgui.Create("DPanel")
    rightPanel.Paint = function(s, w, h) draw.RoundedBox(0, 0, 0, w, h, Color(0, 0, 0, 50)) end
    mainSplit:SetRight(rightPanel)

    -- Helpers
    local function FixLineColors()
        for _, line in pairs(listView:GetLines()) do
            line.Paint = function(s, w, h)
                if s:IsSelected() then draw.RoundedBox(0, 0, 0, w, h, Theme.accent)
                elseif s:IsHovered() then draw.RoundedBox(0, 0, 0, w, h, Color(Theme.accent.r, Theme.accent.g, Theme.accent.b, 30)) end
            end
            for _, col in pairs(line.Columns) do 
                if line.IsFolder then col:SetTextColor(Theme.folder_text) else col:SetTextColor(Theme.file_text) end
            end
        end
    end

    -- SCANNING LOGIC WITH SEARCH SUPPORT
    local currentScannedData = {path = "", folders = {}, files = {}}

    local function PopulateBrowserList(filterText)
        listView:Clear()
        local path = currentScannedData.path
        local filter = string.lower(filterText or "")

        -- Up Button
        if #path > 4 and filter == "" then
            local line = listView:AddLine(".. (Go Up)", "DIR"); line.IsUp = true; line.Path = string.GetPathFromFilename(string.Left(path, #path - 1))
        end

        -- Folders
        for _, folderName in ipairs(currentScannedData.folders) do 
            if filter == "" or string.find(string.lower(folderName), filter) then
                local line = listView:AddLine(folderName, "Folder"); line.Path = path .. folderName; line.IsFolder = true 
            end
        end

        -- Files
        for _, fileName in ipairs(currentScannedData.files) do 
            if filter == "" or string.find(string.lower(fileName), filter) then
                local line = listView:AddLine(fileName, "File"); line.Path = path .. fileName; line.IsFile = true 
            end
        end
        FixLineColors()
    end

    local function ScanAndPopulate(path)
        if not string.EndsWith(path, "/") and not string.EndsWith(path, "\\") then path = path .. "/" end
        pathEntry:SetText(path); lastPath = path; cookie.Set("gabes_music_path", path)
        
        local data = musicplayer.ScanDir(path)
        if not data then return end
        
        -- Store data for search filtering
        currentScannedData.path = path
        currentScannedData.folders = data.folders or {}
        currentScannedData.files = data.files or {}
        
        searchEntry:SetText("") -- Reset search on new folder
        PopulateBrowserList("")
    end

    -- Hook up search bar
    searchEntry.OnChange = function(s)
        PopulateBrowserList(s:GetText())
    end

    -- SHORTCUT LOGIC (Updated for Files and Folders)
    local function RefreshShortcuts()
        shortcutList:Clear()
        
        -- Sort: Folders first (A-Z), then Files (A-Z)
        local sortedShortcuts = {}
        for k, v in pairs(folderShortcuts) do
            table.insert(sortedShortcuts, v)
        end

        table.sort(sortedShortcuts, function(a, b)
            local aType = a.type or "folder"
            local bType = b.type or "folder"
            local aName = string.lower(a.name or "")
            local bName = string.lower(b.name or "")

            if aType == "folder" and bType ~= "folder" then return true end
            if aType ~= "folder" and bType == "folder" then return false end
            
            return aName < bName
        end)

        for _, v in pairs(sortedShortcuts) do
            local line = shortcutList:AddLine(v.name)
            line.Path = v.path
            line.Type = v.type or "folder" -- Default to folder for old cookies
            line.FolderPath = v.folderPath -- Only for file pins
            
            -- Color and Icon Logic
            if line.Type == "folder" then
                if line.Columns[1] then line.Columns[1]:SetTextColor(Theme.folder_text) end
                if line.SetIcon then line:SetIcon("icon16/folder.png") end
            else
                if line.Columns[1] then line.Columns[1]:SetTextColor(Theme.file_text) end
                if line.SetIcon then line:SetIcon("icon16/music.png") end
            end

            line.Paint = function(s, w, h)
                if s:IsSelected() then draw.RoundedBox(0, 0, 0, w, h, Theme.accent)
                elseif s:IsHovered() then draw.RoundedBox(0, 0, 0, w, h, Color(Theme.accent.r, Theme.accent.g, Theme.accent.b, 30)) end
            end
        end
    end
    RefreshShortcuts()

    -- Logic to add a shortcut from code
    local function AddShortcut(name, path, sType, folderPath)
        -- Check duplicates
        for _, v in pairs(folderShortcuts) do if v.path == path then return end end
        
        local entry = {name = name, path = path, type = sType}
        if folderPath then entry.folderPath = folderPath end
        
        table.insert(folderShortcuts, entry)
        SaveShortcuts()
        RefreshShortcuts()
        notification.AddLegacy("Pinned to Sidebar!", NOTIFY_GENERIC, 3)
    end

    btnPinFolder.DoClick = function()
        local path = pathEntry:GetText()
        -- Strip trailing slashes
        local cleanPath = path
        while string.EndsWith(cleanPath, "/") or string.EndsWith(cleanPath, "\\") do
            cleanPath = string.sub(cleanPath, 1, #cleanPath - 1)
        end
        local name = string.GetFileFromFilename(cleanPath) 
        if name == "" then name = path end
        AddShortcut(name, path, "folder")
    end

shortcutList.OnRowSelected = function(lst, idx, pnl)
    if pnl.Type == "folder" then
        ScanAndPopulate(pnl.Path)

    elseif pnl.Type == "file" then
        -- File pin: Go to folder, highlight file, scroll to it
        if pnl.FolderPath then
            ScanAndPopulate(pnl.FolderPath)

            -- Wait one frame for list layout
            timer.Simple(0, function()
                if not IsValid(listView) then return end

                local targetPath = string.Replace(pnl.Path or "", "\\", "/")

                -- Clear selection properly
                listView:ClearSelection()

                for _, line in ipairs(listView:GetLines()) do
                    local linePath = string.Replace(line.Path or "", "\\", "/")

                    if linePath == targetPath then
                        -- ✅ Correct way to select a line
                        line:SetSelected(true)

                        -- ✅ Scroll to the selected line safely
                        if listView.VBar then
                            listView.VBar:SetScroll(line:GetY())
                        end

                        break
                    end
                end
            end)
        end
    end
end


    shortcutList.OnRowRightClick = function(lst, idx, pnl)
        local menu = DermaMenu()
        menu:AddOption("Remove Shortcut", function()
            for k, v in pairs(folderShortcuts) do if v.path == pnl.Path then table.remove(folderShortcuts, k); break end end
            SaveShortcuts(); RefreshShortcuts()
        end):SetIcon("icon16/delete.png")
        menu:Open()
    end

    -- ===========================================================
    -- COLLECTIONS HELPER FUNCTIONS
    -- ===========================================================
    local function RefreshQueueList() end -- Forward decl
    
    frame.CurrentActiveCollection = nil -- Track what we are looking at

    -- [FIX] REFRESH LOGIC FOR COLLECTIONS
    frame.RefreshCollectionSongs = function(colName)
        -- This logic is moved here so it can be called from AddSongToCollection
        if not IsValid(frame) then return end
        -- Note: We need to access colSongList, which we will define in Tab 2. 
        -- We will assign it to frame.colSongList for global access inside frame
        if not IsValid(frame.colSongList) then return end
        
        frame.colSongList:Clear()
        local songs = SavedCollections[colName] or {}
        for _, s in ipairs(songs) do
            local l = frame.colSongList:AddLine(s.name)
            l.Path = s.path
            l.Data = s -- Store full data for removal
            l.Columns[1]:SetTextColor(Theme.text)
        end
    end

    local function AddSongToCollection(colName, path, name)
        if not SavedCollections[colName] then SavedCollections[colName] = {} end
        
        -- Check duplicate in collection
        for _, s in pairs(SavedCollections[colName]) do if s.path == path then return end end
        
        table.insert(SavedCollections[colName], {path = path, name = name})
        SaveCollections()
        notification.AddLegacy("Added to collection: " .. colName, NOTIFY_GENERIC, 3)

        -- [FIX] LIVE REFRESH
        if frame.CurrentActiveCollection == colName then
            frame.RefreshCollectionSongs(colName)
        end
    end

    local function CreateNewCollection(pathToAdd, nameToAdd)
        Derma_StringRequest("New Collection", "Enter a name for new collection:", "", function(text)
            if text == "" then return end
            if SavedCollections[text] then notification.AddLegacy("Collection already exists!", NOTIFY_ERROR, 3); return end
            SavedCollections[text] = {}
            if pathToAdd then AddSongToCollection(text, pathToAdd, nameToAdd) end
            SaveCollections()
            if frame.RefreshCols then frame.RefreshCols() end
        end)
    end

    -- ===========================================================
    -- TAB 2: COLLECTIONS MANAGER
    -- ===========================================================
    local colsPanel = vgui.Create("DPanel", sheet)
    colsPanel.Paint = function() end
    sheet:AddSheet("Collections", colsPanel, "icon16/book.png")

    local colSplit = vgui.Create("DHorizontalDivider", colsPanel); colSplit:Dock(FILL); colSplit:SetLeftWidth(200)
    
    -- LEFT: Collection Names
    local colList = vgui.Create("DListView"); colList:SetMultiSelect(false); colList:AddColumn("Your Collections")
    colList.Paint = function(s,w,h) draw.RoundedBox(0,0,0,w,h,Theme.list_bg); surface.SetDrawColor(Theme.list_border); surface.DrawOutlinedRect(0,0,w,h) end
    colList.Columns[1].Header:SetTextColor(Theme.text)

    -- RIGHT: Songs in Collection
    local colSongList = vgui.Create("DListView"); colSongList:SetMultiSelect(false); colSongList:AddColumn("Songs")
    colSongList.Paint = colList.Paint; colSongList.Columns[1].Header:SetTextColor(Theme.text)
    frame.colSongList = colSongList -- Save ref for refreshing

    colSplit:SetLeft(colList); colSplit:SetRight(colSongList)

    frame.RefreshCols = function()
        colList:Clear()
        colSongList:Clear()
        frame.CurrentActiveCollection = nil
        for name, _ in pairs(SavedCollections) do
            local l = colList:AddLine(name)
            l.ColName = name
            l.Paint = function(s, w, h)
                if s:IsSelected() then draw.RoundedBox(0, 0, 0, w, h, Theme.accent)
                elseif s:IsHovered() then draw.RoundedBox(0, 0, 0, w, h, Color(Theme.accent.r, Theme.accent.g, Theme.accent.b, 30)) end
            end
            l.Columns[1]:SetTextColor(Theme.text)
        end
    end
    frame.RefreshCols()

    colList.OnRowSelected = function(lst, idx, pnl)
        frame.CurrentActiveCollection = pnl.ColName
        frame.RefreshCollectionSongs(pnl.ColName)
    end

    -- [FIX] RIGHT CLICK REMOVE SONG FROM COLLECTION
    colSongList.OnRowRightClick = function(lst, idx, pnl)
        if not frame.CurrentActiveCollection then return end
        
        local menu = DermaMenu()
        menu:AddOption("Remove from Collection", function()
            local colName = frame.CurrentActiveCollection
            local targetPath = pnl.Path
            
            -- Find and remove
            for k, v in pairs(SavedCollections[colName]) do
                if v.path == targetPath then
                    table.remove(SavedCollections[colName], k)
                    break
                end
            end
            
            SaveCollections()
            frame.RefreshCollectionSongs(colName) -- Refresh UI
            notification.AddLegacy("Song removed from " .. colName, NOTIFY_GENERIC, 3)
        end):SetIcon("icon16/delete.png")
        
        menu:AddOption("Play", function() PlayFile(pnl.Path) end):SetIcon("icon16/sound.png")
        menu:Open()
    end

    -- Collection Context Menu (Delete, Load)
    colList.OnRowRightClick = function(lst, idx, pnl)
        local menu = DermaMenu()
        menu:AddOption("Load to Queue", function()
            local songs = SavedCollections[pnl.ColName]
            
            -- [FIX] ADMIN-ONLY QUEUE LOADING
            if LocalPlayer():IsAdmin() then
                -- Network the collection load
                net.Start("MusicPlayer_Queue")
                net.WriteString("load_collection")
                net.WriteString(pnl.ColName)
                net.SendToServer()
                notification.AddLegacy("Loading collection to global queue...", NOTIFY_GENERIC, 3)
            else
                -- Local only
                for _, s in ipairs(songs) do table.insert(ActiveQueue, s) end
                SaveActiveQueue()
                RefreshQueueList()
                notification.AddLegacy("Loaded collection to local queue!", NOTIFY_GENERIC, 3)
            end
        end):SetIcon("icon16/arrow_right.png")
        menu:AddOption("Delete Collection", function()
            SavedCollections[pnl.ColName] = nil
            SaveCollections()
            frame.RefreshCols()
        end):SetIcon("icon16/cross.png")
        menu:Open()
    end

    -- ===========================================================
    -- TAB 3: ACTIVE QUEUE (Formerly Playlist)
    -- ===========================================================
    local queuePanel = vgui.Create("DPanel", sheet)
    queuePanel.Paint = function() end
    sheet:AddSheet("Active Queue", queuePanel, "icon16/music.png") 
    
    local queueControls = vgui.Create("DPanel", queuePanel)
    queueControls:Dock(TOP); queueControls:SetHeight(35); queueControls:DockMargin(0,0,0,5); queueControls.Paint = function() end

    local chkLocal = vgui.Create("DCheckBoxLabel", queueControls)
    chkLocal:Dock(LEFT); chkLocal:SetText("Play Queue Locally Only (Don't network)"); chkLocal:SetTextColor(Theme.text)
    chkLocal:SetFont("DermaDefaultBold"); chkLocal:DockMargin(5, 5, 0, 5); chkLocal:SizeToContents()
    chkLocal:SetValue(isLocalMode)
    chkLocal.OnChange = function(s, val) isLocalMode = val; cookie.Set("gabe_local_mode", val and 1 or 0) end

    -- [FIX] LOOP BUTTON
    local btnLoop = vgui.Create("DButton", queueControls)
    btnLoop:Dock(LEFT); btnLoop:SetText("Loop Track"); btnLoop:SetWidth(100); btnLoop:DockMargin(10, 5, 0, 5)
    btnLoop.Paint = function(s, w, h)
        if isLooping then
            draw.RoundedBox(4, 0, 0, w, h, Theme.accent)
        else
            draw.RoundedBox(4, 0, 0, w, h, Theme.panel_bg)
        end
        surface.SetDrawColor(Theme.outline); surface.DrawOutlinedRect(0,0,w,h)
    end
    btnLoop.DoClick = function()
        isLooping = not isLooping
        notification.AddLegacy(isLooping and "Loop enabled" or "Loop disabled", NOTIFY_GENERIC, 2)
    end

    local btnClearQ = vgui.Create("DButton", queueControls)
    btnClearQ:Dock(RIGHT); btnClearQ:SetText("Clear Queue"); btnClearQ:SetWidth(100)
    
    btnClearQ.DoClick = function()
        -- [FIX] ADMIN-ONLY QUEUE CLEAR
        if LocalPlayer():IsAdmin() then
            net.Start("MusicPlayer_Queue")
            net.WriteString("clear")
            net.SendToServer()
            notification.AddLegacy("Clearing global queue...", NOTIFY_GENERIC, 3)
        else
            ActiveQueue = {}
            SaveActiveQueue()
            RefreshQueueList()
            notification.AddLegacy("Cleared local queue", NOTIFY_GENERIC, 3)
        end
    end

    local queueList = vgui.Create("DListView", queuePanel)
    queueList:Dock(FILL); queueList:SetMultiSelect(false); queueList:AddColumn("#"); queueList:AddColumn("Name"); queueList:AddColumn("Path")
    queueList.Columns[1]:SetFixedWidth(30)
    queueList.Paint = listView.Paint 
    for _, col in pairs(queueList.Columns) do col.Header:SetTextColor(Theme.text); col.Header.Paint = listView.Columns[1].Header.Paint end

    RefreshQueueList = function()
        queueList:Clear()
        for i, v in pairs(ActiveQueue) do
            local line = queueList:AddLine(i, v.name, v.path)
            line.IsFile = true; line.Path = v.path
            line.Index = i
            line.Paint = function(s, w, h)
                if s:IsSelected() then draw.RoundedBox(0, 0, 0, w, h, Theme.accent)
                elseif s:IsHovered() then draw.RoundedBox(0, 0, 0, w, h, Color(Theme.accent.r, Theme.accent.g, Theme.accent.b, 30)) end
            end
            for _, col in pairs(line.Columns) do col:SetTextColor(Theme.text) end
        end
    end
    RefreshQueueList()

    -- [FIX] ADD TO QUEUE LOGIC (Admin-only networking)
    local function AddToQueue(path, name)
        if LocalPlayer():IsAdmin() and not isLocalMode then
            -- Network the addition
            net.Start("MusicPlayer_Queue")
            net.WriteString("add")
            net.WriteString(path)
            net.WriteString(name)
            net.SendToServer()
            notification.AddLegacy("Adding to global queue...", NOTIFY_GENERIC, 3)
        else
            -- Local only
            table.insert(ActiveQueue, {path = path, name = name})
            SaveActiveQueue()
            RefreshQueueList()
            
            -- Auto play if nothing playing
            if not currentStream then
                currentQueueIndex = #ActiveQueue
                PlayFile(path)
                notification.AddLegacy("Starting queue locally...", NOTIFY_GENERIC, 3) 
            else
                notification.AddLegacy("Added to local queue: " .. name, NOTIFY_GENERIC, 3)
            end
        end
    end

    queueList.OnRowRightClick = function(lst, idx, pnl)
        local menu = DermaMenu()
        menu:AddOption("Play Immediately", function() PlayFile(pnl.Path) end):SetIcon("icon16/sound.png")
        
        menu:AddOption("Remove from Queue", function()
            if LocalPlayer():IsAdmin() and not isLocalMode then
                net.Start("MusicPlayer_Queue")
                net.WriteString("remove")
                net.WriteUInt(pnl.Index, 16)
                net.SendToServer()
                notification.AddLegacy("Removing from global queue...", NOTIFY_GENERIC, 3)
            else
                table.remove(ActiveQueue, pnl.Index)
                SaveActiveQueue()
                RefreshQueueList()
            end
        end):SetIcon("icon16/delete.png")
        
        menu:Open()
    end
    
    queueList.DoDoubleClick = function(lst, idx, pnl) 
        PlayFile(pnl.Path) 
    end
    
    -- Main Browser Interactions
    listView.OnRowSelected = function(lst, idx, pnl) if pnl.IsFile then frame.SelectedFile = pnl.Path end end
    listView.DoDoubleClick = function(lst, idx, pnl) if pnl.IsUp or pnl.IsFolder then ScanAndPopulate(pnl.Path) elseif pnl.IsFile then frame.SelectedFile = pnl.Path; PlayFile(pnl.Path) end end
    
    -- Right Click Main Browser [UPDATED WITH ADMIN-ONLY QUEUE]
    listView.OnRowRightClick = function(lst, idx, pnl)
        local menu = DermaMenu()
        
        if pnl.IsFile then
            frame.SelectedFile = pnl.Path
            menu:AddOption("Pin to Sidebar", function()
                AddShortcut(string.GetFileFromFilename(pnl.Path), pnl.Path, "file", string.GetPathFromFilename(pnl.Path))
            end):SetIcon("icon16/star.png")

            menu:AddOption("Play Locally (Immediate)", function() PlayFile(pnl.Path) end):SetIcon("icon16/sound.png")
            
            -- [FIX] ADMIN-ONLY QUEUE ADDITION
            if LocalPlayer():IsAdmin() then
                local subMenu = menu:AddSubMenu("Add to Queue")
                subMenu:AddOption("Add to Local Queue", function() 
                    table.insert(ActiveQueue, {path = pnl.Path, name = string.GetFileFromFilename(pnl.Path)})
                    SaveActiveQueue()
                    RefreshQueueList()
                    notification.AddLegacy("Added to local queue", NOTIFY_GENERIC, 3)
                end):SetIcon("icon16/add.png")
                
                subMenu:AddOption("Add to Global Queue", function()
                    net.Start("MusicPlayer_Queue")
                    net.WriteString("add")
                    net.WriteString(pnl.Path)
                    net.WriteString(string.GetFileFromFilename(pnl.Path))
                    net.SendToServer()
                end):SetIcon("icon16/world.png")
            else
                menu:AddOption("Add to Queue", function() 
                    AddToQueue(pnl.Path, string.GetFileFromFilename(pnl.Path))
                end):SetIcon("icon16/add.png")
            end
            
            -- ADD TO COLLECTION SUBMENU
            local sub = menu:AddSubMenu("Add to Collection")
            sub:AddOption("Create New Collection...", function() CreateNewCollection(pnl.Path, string.GetFileFromFilename(pnl.Path)) end):SetIcon("icon16/add.png")
            
            -- Add existing collections
            for name, _ in pairs(SavedCollections) do
                sub:AddOption(name, function() AddSongToCollection(name, pnl.Path, string.GetFileFromFilename(pnl.Path)) end)
            end

            -- [SECURED] Play for Everyone (Admin only)
            if LocalPlayer():IsAdmin() then
                menu:AddOption("Play for Everyone", function() 
                    net.Start("MusicPlayer_Broadcast"); net.WriteString(pnl.Path); net.SendToServer()
                end):SetIcon("icon16/world.png")
            end
            
        elseif pnl.IsFolder then
            menu:AddOption("Pin to Sidebar", function()
                AddShortcut(pnl:GetColumnText(1), pnl.Path, "folder")
            end):SetIcon("icon16/star.png")

            -- ADD FOLDER TO QUEUE (Admin-only networking)
            local folderQueueMenu = menu:AddSubMenu("Add Folder to Queue")
            
            folderQueueMenu:AddOption("Add to Local Queue", function()
                local data = musicplayer.ScanDir(pnl.Path)
                if data and data.files then
                    local count = 0
                    for _, f in ipairs(data.files) do
                        local ext = string.GetExtensionFromFilename(f)
                        if ext == "mp3" or ext == "wav" or ext == "ogg" then
                             table.insert(ActiveQueue, {path = pnl.Path .. "/" .. f, name = f})
                             count = count + 1
                        end
                    end
                    SaveActiveQueue()
                    RefreshQueueList()
                    notification.AddLegacy("Added " .. count .. " songs to local queue!", NOTIFY_GENERIC, 3)
                else
                    notification.AddLegacy("Error reading folder!", NOTIFY_ERROR, 3)
                end
            end):SetIcon("icon16/music.png")
            
            if LocalPlayer():IsAdmin() then
                folderQueueMenu:AddOption("Add to Global Queue", function()
                    local data = musicplayer.ScanDir(pnl.Path)
                    if data and data.files then
                        local count = 0
                        for _, f in ipairs(data.files) do
                            local ext = string.GetExtensionFromFilename(f)
                            if ext == "mp3" or ext == "wav" or ext == "ogg" then
                                net.Start("MusicPlayer_Queue")
                                net.WriteString("add")
                                net.WriteString(pnl.Path .. "/" .. f)
                                net.WriteString(f)
                                net.SendToServer()
                                count = count + 1
                            end
                        end
                        notification.AddLegacy("Adding " .. count .. " songs to global queue...", NOTIFY_GENERIC, 3)
                    end
                end):SetIcon("icon16/world.png")
            end

            -- ADD FOLDER TO COLLECTION
            local sub = menu:AddSubMenu("Add Folder to Collection")
            sub:AddOption("Create New...", function() 
                Derma_StringRequest("New Collection", "Enter name:", "", function(text)
                    if text == "" then return end
                    if SavedCollections[text] then return end
                    SavedCollections[text] = {}
                    
                    -- Add files
                    local data = musicplayer.ScanDir(pnl.Path)
                    if data and data.files then
                        for _, f in ipairs(data.files) do
                            local ext = string.GetExtensionFromFilename(f)
                            if ext == "mp3" or ext == "wav" or ext == "ogg" then
                                table.insert(SavedCollections[text], {path = pnl.Path .. "/" .. f, name = f})
                            end
                        end
                    end
                    SaveCollections()
                    frame.RefreshCols()
                    notification.AddLegacy("Created collection: " .. text, NOTIFY_GENERIC, 3)
                end)
            end):SetIcon("icon16/add.png")

            for name, _ in pairs(SavedCollections) do
                sub:AddOption(name, function() 
                    local data = musicplayer.ScanDir(pnl.Path)
                    if data and data.files then
                        local count = 0
                        for _, f in ipairs(data.files) do
                            local ext = string.GetExtensionFromFilename(f)
                            if ext == "mp3" or ext == "wav" or ext == "ogg" then
                                AddSongToCollection(name, pnl.Path .. "/" .. f, f)
                                count = count + 1
                            end
                        end
                        notification.AddLegacy("Added " .. count .. " songs to " .. name, NOTIFY_GENERIC, 3)
                    end
                end)
            end
        end
        
        menu:Open()
    end

    btnScan.DoClick = function() ScanAndPopulate(pathEntry:GetText()) end
    
    -- ===========================================================
    -- RIGHT PANEL (CONTROLS) CONTENT
    -- ===========================================================
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
                surface.SetDrawColor(Theme.vis_color)
                local volMultiplier = math.max(currentVolume * 10, 10)
                for i = 1, #fftData do
                    local val = math.Clamp(fftData[i] * volMultiplier, 0, 10)
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
        draw.RoundedBox(2, 0, h/2 - 2, w * s:GetSlideX(), 4, Theme.accent)
    end
    seekSlider.Knob.Paint = function(s, w, h) draw.RoundedBox(8, 0, 0, w, h, Theme.text) end
    seekSlider.OnValueChanged = function(self, val)
    if not self:IsEditing() or currentDuration <= 0 then return end

    local pos = val * currentDuration
    lblTime:SetText(SecondsToTime(pos) .. " / " .. SecondsToTime(currentDuration))

    -- 🌍 REALTIME SEEK BROADCAST (Admins only)
    if isNetworkedPlayback and LocalPlayer():IsAdmin() then
        net.Start("MusicPlayer_Control")
            net.WriteString("seek")
            net.WriteFloat(pos)
            net.WriteFloat(0)
        net.SendToServer()
    end
end

seekSlider.OnMousePressed = function(self, m)
    if m ~= MOUSE_LEFT then return end
    if currentDuration <= 0 then return end

    -- Convert mouse X to slider position
    local x = self:ScreenToLocal(gui.MouseX(), gui.MouseY())
    local frac = math.Clamp(x / self:GetWide(), 0, 1)

    self:SetSlideX(frac)

    local pos = frac * currentDuration

    -- Apply seek immediately
    if isNetworkedPlayback and LocalPlayer():IsAdmin() then
        net.Start("MusicPlayer_Control")
            net.WriteString("seek")
            net.WriteFloat(pos)
            net.WriteFloat(0)
        net.SendToServer()
    else
        if currentStream then
            musicplayer.SetPos(currentStream, pos)
        end
    end

    self:MouseCapture(true)
end

    
    seekSlider.Knob.OnMouseReleased = function(self, m) 
        local pos = seekSlider:GetSlideX() * currentDuration
        if isNetworkedPlayback then
             net.Start("MusicPlayer_Control"); net.WriteString("seek"); net.WriteFloat(pos); net.WriteFloat(0); net.SendToServer()
        else
            if currentStream then musicplayer.SetPos(currentStream, pos) end 
        end
        self:MouseCapture(false); return DButton.OnMouseReleased(self, m) 
    end

    local function CreateCustomSlider(parent, label, min, max, default, onSlide)
        local panel = vgui.Create("DPanel", parent); panel:Dock(TOP); panel:SetHeight(50); panel:DockMargin(10, 5, 10, 5); panel.Paint = function() end
        local topBar = vgui.Create("DPanel", panel); topBar:Dock(TOP); topBar:SetHeight(20); topBar.Paint = function() end
        local lbl = vgui.Create("DLabel", topBar); lbl:Dock(LEFT); lbl:SetWidth(200); lbl:SetText(label); lbl:SetTextColor(Theme.text); lbl:SetFont("DermaDefaultBold")
        local valLbl = vgui.Create("DLabel", topBar); valLbl:Dock(RIGHT); valLbl:SetWidth(50); valLbl:SetText(string.format("%.2f", default)); valLbl:SetTextColor(Theme.accent); valLbl:SetFont("DermaDefaultBold"); valLbl:SetContentAlignment(6); valLbl:SetMouseInputEnabled(true); valLbl:SetCursor("hand")
        local slider = vgui.Create("DSlider", panel); slider:Dock(FILL); slider:DockMargin(0, 5, 0, 0); slider:SetLockY(0.5); slider:SetSlideX((default - min) / (max - min))
        slider.CurrentVal = default

        local function UpdateValue(num, fromNet)
             num = math.Clamp(num, min, max)
             slider:SetSlideX((num - min) / (max - min)); valLbl:SetText(string.format("%.2f", num)); slider.CurrentVal = num
             if not fromNet then onSlide(num) end
        end

        valLbl.DoDoubleClick = function()
            local edit = vgui.Create("DTextEntry", topBar); edit:SetPos(valLbl:GetPos()); edit:SetSize(valLbl:GetSize()); edit:SetText(valLbl:GetText()); edit:SetFont("DermaDefaultBold"); edit:RequestFocus(); edit:SelectAllText()
            local function Submit() if IsValid(edit) then local num = tonumber(edit:GetText()) if num then UpdateValue(num) end edit:Remove(); valLbl:SetVisible(true) end end
            edit.OnEnter = Submit; edit.OnLoseFocus = Submit; valLbl:SetVisible(false) 
        end

        slider.Paint = function(s, w, h) draw.RoundedBox(2, 0, h/2 - 2, w, 4, Color(0, 0, 0, 255)); draw.RoundedBox(2, 0, h/2 - 2, w * s:GetSlideX(), 4, Theme.accent) end
        slider.Knob.Paint = function(s, w, h) draw.RoundedBox(8, 0, 0, w, h, Theme.text) end
        slider.OnValueChanged = function(s)
		local finalVal = min + (s:GetSlideX() * (max - min))
		valLbl:SetText(string.format("%.2f", finalVal))
		slider.CurrentVal = finalVal
		onSlide(finalVal)

		-- 🌍 REALTIME NETWORK BROADCAST (Admins only)
		if isNetworkedPlayback and LocalPlayer():IsAdmin() then
			local vol = currentVolume
			local pitch = 1.0
			if frame.PitchSlider then pitch = frame.PitchSlider.CurrentVal end

			net.Start("MusicPlayer_Control")
				net.WriteString("update")
				net.WriteFloat(vol)
				net.WriteFloat(pitch)
			net.SendToServer()
		end
	end

        slider.Knob.OnMouseReleased = function(self, m)
             if isNetworkedPlayback then
                 local pitch = 1.0; if frame.PitchSlider then pitch = frame.PitchSlider.CurrentVal end
                 net.Start("MusicPlayer_Control"); net.WriteString("update"); net.WriteFloat(currentVolume); net.WriteFloat(pitch); net.SendToServer()
             end
             self:MouseCapture(false); return DButton.OnMouseReleased(self, m)
        end
        return slider
    end

    local btnPlay = vgui.Create("DButton", rightPanel); btnPlay:Dock(TOP); btnPlay:DockMargin(20, 10, 20, 10); btnPlay:SetHeight(40); btnPlay:SetText("PLAY SELECTED"); btnPlay:SetTextColor(Color(255,255,255))
    btnPlay:SetFont("DermaDefaultBold")
    btnPlay.Paint = function(s, w, h) draw.RoundedBox(4, 0, 0, w, h, Theme.accent); surface.SetDrawColor(Theme.outline); surface.DrawOutlinedRect(0,0,w,h) end
    btnPlay.DoClick = function() if frame.SelectedFile then PlayFile(frame.SelectedFile) end end

    local btnStop = vgui.Create("DButton", rightPanel); btnStop:Dock(TOP); btnStop:DockMargin(20, 0, 20, 20); btnStop:SetHeight(30); btnStop:SetText("STOP"); btnStop:SetTextColor(Color(255,255,255))
    btnStop.Paint = function(s,w,h) draw.RoundedBox(4,0,0,w,h, Color(180, 50, 50)) end
    frame.btnStop = btnStop
    
btnStop.DoClick = function()
    -- 🌍 Admin stops for everyone
    if isNetworkedPlayback and LocalPlayer():IsAdmin() then
        net.Start("MusicPlayer_Control")
            net.WriteString("stop")
            net.WriteFloat(0)
            net.WriteFloat(0)
        net.SendToServer()

    -- 🧍 Non-admin: stop locally only
    else
        if currentStream then
            musicplayer.Stop(currentStream)
            currentStream = nil
            currentSongName = "Stopped (Local)"
            seekSlider:SetSlideX(0)
        end
    end

    amITheDJ = false
end


    frame.VolSlider = CreateCustomSlider(rightPanel, "Volume", 0, 10, 0.5, function(val) currentVolume = val; if currentStream then musicplayer.SetVolume(currentStream, val) end end)
    frame.PitchSlider = CreateCustomSlider(rightPanel, "Pitch / Speed", 0.1, 10, 1.0, function(val) if currentStream then musicplayer.SetPitch(currentStream, val) end end)

    local lastPlayedPath = nil

    function PlayFile(path)
        if currentStream then musicplayer.Stop(currentStream) end
        isNetworkedPlayback = false -- Reset net flag if playing locally
        lastPlayedPath = path
        
        if IsValid(frame.btnStop) then frame.btnStop:SetText("STOP"); frame.btnStop.Paint = function(s,w,h) draw.RoundedBox(4,0,0,w,h, Color(180, 50, 50)) end end
        
        -- Identify if this song is in our queue
        currentQueueIndex = 0
        for i, song in ipairs(ActiveQueue) do
            if song.path == path then currentQueueIndex = i break end
        end

        GlobalMusicStream = musicplayer.Play(path)
        currentStream = GlobalMusicStream
        if currentStream then
            currentDuration = musicplayer.GetLength(currentStream)
            musicplayer.SetVolume(currentStream, currentVolume)
            if frame.PitchSlider then musicplayer.SetPitch(currentStream, frame.PitchSlider.CurrentVal) end
            currentSongName = string.GetFileFromFilename(path) 
            lblTime:SetText("0:00 / " .. SecondsToTime(currentDuration))
        else
            currentSongName = "Error: Failed to Load"
        end
    end

    -- ===========================================================
    -- TAB 4: SETTINGS
    -- ===========================================================
    local settingsPanel = vgui.Create("DPanel", sheet)
    settingsPanel.Paint = function(s, w, h) draw.RoundedBox(0, 0, 0, w, h, Theme.panel_bg) end
    sheet:AddSheet("Settings", settingsPanel, "icon16/palette.png")
    
    local titlePanel = vgui.Create("DPanel", settingsPanel); titlePanel:Dock(TOP); titlePanel:SetHeight(50); titlePanel:DockMargin(10,10,10,0); titlePanel.Paint = function() end
    local lblTitle = vgui.Create("DLabel", titlePanel); lblTitle:Dock(TOP); lblTitle:SetText("Window Title Name:"); lblTitle:SetTextColor(Theme.text); lblTitle:SetFont("DermaDefaultBold")
    local txtTitle = CreateStyledEntry(titlePanel); txtTitle:Dock(LEFT); txtTitle:SetWidth(400); txtTitle:SetText(customTitle)
    local btnSetTitle = vgui.Create("DButton", titlePanel); btnSetTitle:Dock(LEFT); btnSetTitle:SetText("Set Title"); btnSetTitle:SetWidth(100); btnSetTitle:DockMargin(5,0,0,0)
    btnSetTitle.DoClick = function() customTitle = txtTitle:GetText(); cookie.Set("gabe_custom_title", customTitle); frame:Close(); InitMusicSystem() end

    local appearancePanel = vgui.Create("DPanel", settingsPanel); appearancePanel:Dock(TOP); appearancePanel:SetHeight(220); appearancePanel:DockMargin(10,10,10,0); appearancePanel.Paint = function() end
    local leftCol = vgui.Create("DPanel", appearancePanel); leftCol:Dock(LEFT); leftCol:SetWidth(250); leftCol:DockMargin(0, 0, 10, 0); leftCol.Paint = function() end
    local lblMixer = vgui.Create("DLabel", leftCol); lblMixer:Dock(TOP); lblMixer:SetText("Visualizer Color:"); lblMixer:SetTextColor(Theme.text); lblMixer:SetFont("DermaDefaultBold"); lblMixer:DockMargin(0, 0, 0, 5)
    local mixer = vgui.Create("DColorMixer", leftCol); mixer:Dock(FILL); mixer:SetPalette(false); mixer:SetAlphaBar(false); mixer:SetWangs(false); mixer:SetColor(Theme.vis_color)
    mixer.ValueChanged = function(s, col) Theme.vis_color = col; cookie.Set("gabe_vis_color", string.format("%d %d %d", col.r, col.g, col.b)) end

    local rightCol = vgui.Create("DPanel", appearancePanel); rightCol:Dock(FILL); rightCol.Paint = function() end
    local lblAlpha = vgui.Create("DLabel", rightCol); lblAlpha:Dock(TOP); lblAlpha:SetText(""); lblAlpha:SetTextColor(Theme.text); lblAlpha:SetFont("DermaDefaultBold"); lblAlpha:DockMargin(0, 0, 0, 5)
    local alphaSlider = vgui.Create("DNumSlider", rightCol); alphaSlider:Dock(TOP); alphaSlider:SetText(""); alphaSlider:SetMinMax(0, 255); alphaSlider:SetDecimals(0); alphaSlider:SetValue(Theme.bgAlpha)
    alphaSlider.Label:SetTextColor(Theme.text); alphaSlider.OnValueChanged = function(s, val) Theme.bgAlpha = val; cookie.Set("gabe_bg_alpha", val) end

    local resetPanel = vgui.Create("DPanel", settingsPanel); resetPanel:Dock(BOTTOM); resetPanel:SetHeight(40); resetPanel:DockMargin(10, 5, 10, 10); resetPanel.Paint = function() end
    local btnReset = vgui.Create("DButton", resetPanel); btnReset:Dock(RIGHT); btnReset:SetText("Reset Background"); btnReset:SetWidth(150); btnReset:SetTextColor(Color(255, 80, 80))
    btnReset.DoClick = function() SetBackgroundImage("") end

    local bgPanel = vgui.Create("DPanel", settingsPanel); bgPanel:Dock(FILL); bgPanel:DockMargin(10,10,10,5); bgPanel.Paint = function() end
    local lblBg = vgui.Create("DLabel", bgPanel); lblBg:Dock(TOP); lblBg:SetText("Select Background Image (Local File):"); lblBg:SetTextColor(Theme.text); lblBg:SetFont("DermaDefaultBold")
    local bgTree = vgui.Create("DTree", bgPanel); bgTree:Dock(FILL); bgTree:DockMargin(0, 5, 0, 0)
    bgTree.Paint = function(s, w, h) draw.RoundedBox(4, 0, 0, w, h, Theme.list_bg); surface.SetDrawColor(Theme.list_border); surface.DrawOutlinedRect(0, 0, w, h) end

    local function PopulateNode(node, folder)
        local files, dirs = file.Find(folder .. "/*", "GAME")
        for _, dir in ipairs(dirs) do local n = node:AddNode(dir); n.Folder = folder .. "/" .. dir; n.DoClick = function(self) if not self.Populated then PopulateNode(self, self.Folder); self.Populated = true end end end
        for _, f in ipairs(files) do if string.EndsWith(f, ".png") or string.EndsWith(f, ".jpg") or string.EndsWith(f, ".vmt") then local n = node:AddNode(f); n:SetIcon("icon16/picture.png"); n.Path = folder .. "/" .. f; n.DoClick = function() SetBackgroundImage(n.Path) end end end
    end
    local rootData = bgTree:AddNode("data"); rootData.Folder = "data"; rootData.DoClick = function(s) if not s.Populated then PopulateNode(s, "data") s.Populated=true end end
    local rootMats = bgTree:AddNode("materials"); rootMats.Folder = "materials"; rootMats.DoClick = function(s) if not s.Populated then PopulateNode(s, "materials") s.Populated=true end end

    ThemeTabs(sheet)
    btnScan:DoClick()
    
-- TIMER (UI UPDATE + QUEUE CHECK)
local timerName = "MusicPlayerUpdateUI"
timer.Create(timerName, 0.05, 0, function()
    if not IsValid(frame) then
        timer.Remove(timerName)
        return
    end

    if not currentStream then return end

    -- 1. Update Slider
    if not seekSlider:IsEditing() then
        local pos = musicplayer.GetPos(currentStream)
        if not pos or pos < 0 then pos = 0 end

        if currentDuration > 0 then
            seekSlider:SetSlideX(pos / currentDuration)
            lblTime:SetText(SecondsToTime(pos) .. " / " .. SecondsToTime(currentDuration))
        end

        -- 2. END-OF-TRACK HANDLING
        if pos >= (currentDuration - 0.15) then

            -- 🔁 LOOP CURRENT TRACK (FULL RESTART)
            if isLooping then
                local path = nil

                -- Prefer queue path if available
                if currentQueueIndex > 0 and ActiveQueue[currentQueueIndex] then
                    path = ActiveQueue[currentQueueIndex].path
                elseif lastPlayedPath then
                    path = lastPlayedPath
                end

                if not path then return end

                if isNetworkedPlayback and amITheDJ then
                    net.Start("MusicPlayer_Broadcast")
                        net.WriteString(path)
                    net.SendToServer()
                else
                    PlayFile(path)
                end

                seekSlider:SetSlideX(0)
                lblTime:SetText("0:00 / " .. SecondsToTime(currentDuration))
                return
            end

            -- ▶ NORMAL QUEUE ADVANCE
            if currentQueueIndex > 0 then
                local nextIndex = currentQueueIndex + 1
                local nextSong = ActiveQueue[nextIndex]

                if nextSong then
                    if isNetworkedPlayback and amITheDJ then
                        net.Start("MusicPlayer_Broadcast")
                            net.WriteString(nextSong.path)
                        net.SendToServer()
                        notification.AddLegacy("Auto-playing next global song...", NOTIFY_GENERIC, 3)
                        currentQueueIndex = nextIndex

                    elseif not isNetworkedPlayback then
                        PlayFile(nextSong.path)
                        notification.AddLegacy("Auto-playing next local song...", NOTIFY_GENERIC, 3)
                        currentQueueIndex = nextIndex
                    end
                else
                    if not isNetworkedPlayback or amITheDJ then
                        notification.AddLegacy("Queue Finished.", NOTIFY_GENERIC, 3)
                        currentQueueIndex = 0
                    end
                end
            end
        end
    end
end)
end

-- =========================================================
-- OPEN COMMAND (Must be after InitMusicSystem definition)
-- =========================================================

net.Receive("MusicPlayer_Open", function()
    InitMusicSystem()
end)

concommand.Add("open_mp", InitMusicSystem)

hook.Add("OnPlayerChat", "GabesPlayerChatCommand", function(ply, text)
    -- Client side fallback / instant open
    if ply == LocalPlayer() and (string.lower(text) == "/mp" or string.lower(text) == "!mp") then 
        InitMusicSystem(); 
        return true 
    end
end)

hook.Add("Think", "GabesPlayerRestore", function()
    if isHidden and IsValid(playerFrame) then
        if input.IsKeyDown(KEY_C) and input.IsMouseDown(MOUSE_MIDDLE) then
             playerFrame:SetVisible(true); playerFrame:MakePopup(); isHidden = false
        end
    end
end)

hook.Add("InitPostEntity", "GabesPlayerWelcome", function()
    timer.Simple(2, function() notification.AddLegacy("Welcome! Type /mp or !mp or open_mp in console to listen to music.", NOTIFY_HINT, 10) end)
end)