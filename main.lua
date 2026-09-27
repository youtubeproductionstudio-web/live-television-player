require "import"
import "com.androlua.Http"
import "android.widget.Toast"
import "android.app.AlertDialog"
import "android.view.WindowManager"
import "android.os.Handler"
import "android.os.Looper"
import "java.io.File"
import "android.widget.ScrollView"
import "android.widget.LinearLayout"
import "android.widget.TextView"
import "android.util.Log"
import "android.content.DialogInterface"

-- ActionBar hide karne ka check
if activity and activity.getActionBar() then
    activity.getActionBar().hide()
end

local baseUrl = "https://raw.githubusercontent.com/youtubeproductionstudio-web/Yps/refs/heads/main/"
local updateURL = baseUrl .. "Version.txt" 
local notesURL = baseUrl .. "Notes.txt"    
local fileListURL = baseUrl .. "files.txt" -- Yahan nayi files.txt ka link hai

if activity then
    Toast.makeText(activity, "Checking for updates, please wait...", Toast.LENGTH_LONG).show()
end

local TAG = "LuaUpdater"
local currentVersion = "4.03"

local currentPath = ...
local currentDir = nil

if currentPath and type(currentPath) == "string" then
    currentDir = currentPath:match("(.*/)")
end

if not currentDir then
    if activity then
        currentDir = tostring(activity.getLuaDir()) .. "/"
    else
        currentDir = "/storage/emulated/0/瑙ｈ/Tools/Card games version 1.1./"
    end
end

if currentDir and not currentDir:find("/$") then
    currentDir = currentDir .. "/"
end

local mainPath = currentDir .. "update.lua"

Log.i(TAG, "Environment Path Auditing Logs")

local oldMainDialog = nil
local currentUpdateDialog = nil
local currentSuccessDialog = nil

local function isContextValid(ctx)
    if not ctx then return false end
    if activity then
        if activity.isFinishing() or activity.isDestroyed() then
            return false
        end
    end
    return true
end

local function closeToolCompletely(ctx)
    Log.w(TAG, "Terminating host environment completely.")
    pcall(function()
        if currentUpdateDialog and currentUpdateDialog.isShowing() then currentUpdateDialog.dismiss() end
        if currentSuccessDialog and currentSuccessDialog.isShowing() then currentSuccessDialog.dismiss() end
        if oldMainDialog and oldMainDialog.isShowing() then oldMainDialog.dismiss() end
    end)

    if activity then
        pcall(function() activity.finish() end)
    end
end

local function showErrorDialog(ctx, message)
    Handler(Looper.getMainLooper()).post(Runnable{run=function()
        if not isContextValid(ctx) then return end
        local errorDlg = AlertDialog.Builder(ctx)
        errorDlg.setTitle("Update Error")
        errorDlg.setMessage(message .. "\n\nThe tool will now close.")
        errorDlg.setPositiveButton("OK", function(d, w)
            closeToolCompletely(ctx)
        end)
        local d = errorDlg.create()
        d.setCancelable(false)
        pcall(function() d.show() end)
    end})
end

local function runOriginalCode()
    if startAppUiFlow then
        startAppUiFlow()
    end
end

local function checkUpdate()
    Log.i(TAG, "Update checking started. Current local version: [" .. tostring(currentVersion) .. "]")
    
    -- FIRST TIME UPDATE FORCE CHECK
    local forceUpdateFlagPath = currentDir .. ".first_update_done"
    local forceUpdate = false
    local fFlag = io.open(forceUpdateFlagPath, "r")
    if not fFlag then
        forceUpdate = true
        -- Flag file create kar do taake next time yeh true na ho
        local fw = io.open(forceUpdateFlagPath, "w")
        if fw then
            fw:write("done")
            fw:close()
        end
    else
        fFlag:close()
    end

    Http.get(updateURL, function(code, response)
        if code == 200 and response then
            local rawOnlineVersion = tostring(response)
            local onlineVersion = rawOnlineVersion:gsub("[^%w%.%-]", "")
            
            if onlineVersion == "" then
                Log.e(TAG, "Sanitization error: onlineVersion payload reduced to empty string.")
                runOriginalCode()
                return
            end
            
            -- Yahan forceUpdate ka check daal diya hai
            if forceUpdate or (onlineVersion ~= currentVersion) then
                Http.get(notesURL, function(nCode, nResponse)
                    local notesText = ""
                    if nCode == 200 and nResponse then
                        notesText = tostring(nResponse)
                    end
                    
                    Handler(Looper.getMainLooper()).post(Runnable{run=function()
                        local ctx = activity
                        if not isContextValid(ctx) then return end
                        
                        local updateAlertDlg = AlertDialog.Builder(ctx)
                        updateAlertDlg.setTitle("New Update Available!")
                        
                        local scrollView = ScrollView(ctx)
                        local linearLayout = LinearLayout(ctx)
                        linearLayout.setOrientation(LinearLayout.VERTICAL)
                        linearLayout.setPadding(40, 40, 40, 40)
                        scrollView.addView(linearLayout)
                        
                        -- Professional Strings for Version Info
                        local tvServer = TextView(ctx)
                        tvServer.setText("馃敼 Latest Release : Version " .. onlineVersion)
                        tvServer.setTextSize(16)
                        linearLayout.addView(tvServer)
                        
                        local tvCurrent = TextView(ctx)
                        tvCurrent.setText("馃敻 Current Build : Version " .. currentVersion .. "\n")
                        tvCurrent.setTextSize(15)
                        linearLayout.addView(tvCurrent)
                        
                        if notesText ~= "" then
                            for line in notesText:gmatch("[^\r\n]+") do
                                local tvLine = TextView(ctx)
                                tvLine.setText(line)
                                tvLine.setTextSize(15)
                                tvLine.setPadding(0, 0, 0, 10)
                                linearLayout.addView(tvLine)
                            end
                        end
                        
                        updateAlertDlg.setView(scrollView)
                        updateAlertDlg.setPositiveButton("Download Update", nil)
                        updateAlertDlg.setNegativeButton("Later", nil)
                        
                        updateAlertDlg.setOnCancelListener(DialogInterface.OnCancelListener{
                            onCancel = function(dialog)
                                closeToolCompletely(ctx)
                            end
                        })
                        
                        currentUpdateDialog = updateAlertDlg.create()
                        currentUpdateDialog.setCanceledOnTouchOutside(false)
                        
                        local successShow, errShow = pcall(function() currentUpdateDialog.show() end)
                        if not successShow then return end
                        
                        local btnUpdate = currentUpdateDialog.getButton(AlertDialog.BUTTON_POSITIVE)
                        local btnLater = currentUpdateDialog.getButton(AlertDialog.BUTTON_NEGATIVE)
                        
                        btnLater.onClick = function(v)
                            closeToolCompletely(ctx)
                        end

                        btnUpdate.onClick = function(v)
                            v.setText("Fetching Resources for update...")
                            v.setEnabled(false)
                            btnLater.setEnabled(false)
                            
                            local dirFile = File(currentDir)
                            if not dirFile.exists() then dirFile.mkdirs() end
                            
                            -- SAB SE PEHLE files.txt DOWNLOAD KAREIN
                            Http.get(fileListURL, function(listCode, listResponse)
                                if listCode ~= 200 or not listResponse then
                                    showErrorDialog(ctx, "files.txt list download nahi ho saki. Update shuru nahi ho sakta.")
                                    return
                                end
                                
                                local dynamicFilesToUpdate = {}
                                local listData = tostring(listResponse)
                                
                                -- Text file ko line-by-line read karna
                                for filename in listData:gmatch("[^\r\n]+") do
                                    local trimmedName = filename:gsub("^%s*(.-)%s*$", "%1") -- Extra spaces remove karne ke liye
                                    if trimmedName ~= "" then
                                        -- Space walay names ko URL link may theek karnay k liye
                                        local encodedUrl = trimmedName:gsub(" ", "%%20")
                                        table.insert(dynamicFilesToUpdate, {
                                            name = trimmedName,
                                            url = baseUrl .. encodedUrl
                                        })
                                    end
                                end
                                
                                local totalFiles = #dynamicFilesToUpdate
                                if totalFiles == 0 then
                                    showErrorDialog(ctx, "files.txt bilkul khali hai. Koi files update nahi hui.")
                                    return
                                end

                                Handler(Looper.getMainLooper()).post(Runnable{run=function()
                                    if v then v.setText("Preparing download...") end
                                end})
                                
                                -- Multi-file download loop
                                local function downloadNextFile(index)
                                    if index > totalFiles then
                                        -- Saari files download ho gayi hain, ab version update.lua may replace karo
                                        local writeSuccess = true
                                        local mf, mfErr = io.open(mainPath, "r")
                                        if mf then
                                            local mainContent = mf:read("*a")
                                            mf:close()
                                            
                                            local pattern = 'local%s+currentVersion%s*=%s*["\'](.-)["\']'
                                            local escapedOnlineVersion = onlineVersion:gsub("%%", "%%%%")
                                            local replacementString = 'local currentVersion = "' .. escapedOnlineVersion .. '"'
                                            
                                            local newMainContent, matchCount = mainContent:gsub(pattern, function() return replacementString end, 1)
                                            
                                            if matchCount > 0 and newMainContent and newMainContent ~= "" then
                                                local testFunc, compileErr = loadstring(newMainContent, "main_syntax_test")
                                                if testFunc then
                                                    local mf2, mf2Err = io.open(mainPath, "w")
                                                    if mf2 then 
                                                        mf2:write(newMainContent)
                                                        mf2:flush()
                                                        mf2:close() 
                                                        currentVersion = onlineVersion
                                                    else
                                                        writeSuccess = false
                                                    end
                                                else
                                                    writeSuccess = false
                                                end
                                            else
                                                writeSuccess = false
                                            end
                                        else
                                            writeSuccess = false
                                        end
                                        
                                        if writeSuccess then
                                            Handler(Looper.getMainLooper()).post(Runnable{run=function()
                                                if currentUpdateDialog then
                                                    pcall(function() currentUpdateDialog.dismiss() end)
                                                    currentUpdateDialog = nil
                                                end
                                                
                                                if not isContextValid(ctx) then return end

                                                local successDialog = AlertDialog.Builder(ctx)
                                                successDialog.setTitle("Update Successful")
                                                
                                                math.randomseed(os.time())
                                                local messages = {
                                                    [[Congratulations! You have successfully unlocked an incredible premium experience designed exclusively to elevate your journey to absolute perfection.
This feature is developed by Muhammad Hussain.]],
                                                    [[Welcome to the future of pure premium entertainment where your satisfaction and engagement remain our absolute topmost priority.
This feature is developed by Muhammad Hussain.]]
                                                }

                                                local msgIndex = math.random(1, #messages)
                                                local selectedMessage = messages[msgIndex]

                                                local successScrollView = ScrollView(ctx)
                                                local successLayout = LinearLayout(ctx)
                                                successLayout.setOrientation(LinearLayout.VERTICAL)
                                                successLayout.setPadding(40, 40, 40, 40)
                                                successScrollView.addView(successLayout)

                                                for line in selectedMessage:gmatch("[^\r\n]+") do
                                                    local tvLine = TextView(ctx)
                                                    tvLine.setText(line)
                                                    tvLine.setTextSize(15)
                                                    tvLine.setPadding(0, 0, 0, 12)
                                                    successLayout.addView(tvLine)
                                                end

                                                successDialog.setView(successScrollView)
                                                successDialog.setCancelable(false)
                                                successDialog.setPositiveButton("Okay", nil)
                                                
                                                currentSuccessDialog = successDialog.create()
                                                
                                                local successDlgShow, errDlgShow = pcall(function() currentSuccessDialog.show() end)
                                                if not successDlgShow then return end

                                                local btnRestart = currentSuccessDialog.getButton(AlertDialog.BUTTON_POSITIVE)
                                                btnRestart.onClick = function(vx)
                                                    pcall(function() 
                                                        if currentSuccessDialog and currentSuccessDialog.isShowing() then currentSuccessDialog.dismiss() end
                                                    end)
                                                    if activity then
                                                        pcall(function() activity.finish() end)
                                                    end
                                                end
                                            end})
                                        else
                                            showErrorDialog(ctx, "Update apply karte waqt error aaya. Update file ko likhne mein masla hai.")
                                        end
                                        return
                                    end
                                    
                                    -- **PROGRESS TRACKING UI UPDATE**
                                    Handler(Looper.getMainLooper()).post(Runnable{run=function()
                                        if v then
                                            local percent = math.floor((index / totalFiles) * 100)
                                            v.setText(string.format("Downloading: %d%% (%d / %d)", percent, index, totalFiles))
                                        end
                                    end})
                                    
                                    local currentFile = dynamicFilesToUpdate[index]
                                    Http.get(currentFile.url, function(c, content)
                                        if c ~= 200 or not content or tostring(content):gsub("^%s*(.-)%s*$", "%1") == "" then
                                            showErrorDialog(ctx, "Download failed for " .. currentFile.name .. ". Please check internet connection.")
                                            return
                                        end
                                        
                                        local filePath = currentDir .. currentFile.name
                                        local f, fErr = io.open(filePath, "w")
                                        if f then 
                                            f:write(tostring(content)) 
                                            f:close() 
                                            -- Recursive call agli file kay liye
                                            downloadNextFile(index + 1)
                                        else
                                            showErrorDialog(ctx, "Failed to write data to " .. currentFile.name)
                                            return
                                        end
                                    end)
                                end
                                
                                -- Peli file se downloading process shuru karein
                                downloadNextFile(1)
                            end)
                        end
                    end})
                end)
            else
                runOriginalCode()
            end
        else
            runOriginalCode()
        end
    end)
end

checkUpdate()