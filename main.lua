require "import"
import "android.widget.*"
import "android.view.*"
import "android.content.Intent"
import "android.net.Uri"
import "android.widget.VideoView"
import "android.widget.CompoundButton"
import "android.content.pm.ActivityInfo"
import "java.util.Locale"
import "android.os.Handler"
import "java.lang.Runnable"
import "android.text.TextWatcher"
import "android.content.DialogInterface"
import "android.widget.AdapterView"
import "java.net.URLEncoder"
import "android.text.InputType"
import "android.media.MediaPlayer"
import "android.speech.RecognizerIntent"
import "android.app.Activity"
import "android.graphics.Typeface"
import "android.widget.SeekBar"
import "android.media.AudioManager"
import "android.content.Context"
import "android.media.audiofx.LoudnessEnhancer"
import "android.app.AlertDialog"
import "java.util.HashMap"
import "android.content.ClipboardManager"
import "android.content.ClipData"

local cjson = require "cjson"

-- Global State & Fallbacks
local all_channels = {}
local filtered_channels = {}
local current_playlist = {} 
local all_countries = {}
local all_categories = {} 
local favorites_list = {}
local history_list = {}
local search_history_list = {}
local stream_map = {}
local current_playing_index = -1
local current_stream_channel = nil
local last_saved_query = ""
local current_quality_setting = "Auto (Best Quality)"

-- Playback Session Management to prevent stale callbacks
local current_playback_session = 0
local player_timeout_handler = Handler()
local favorites_dialog_refresh = nil

local prefs = this.getSharedPreferences("TVAppPrefs", 0)
local editor = prefs.edit()
local current_country = prefs.getString("last_country", "All Countries")
local current_category = "All Categories"

-- Always stay in Portrait mode for the app UI
this.setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT)

-- Safe Error Handler Wrapper
local function safeCall(func, ...)
    local status, result = pcall(func, ...)
    if not status then
        print("Error encountered: " .. tostring(result))
    end
    return status, result
end

-- TTS Accessibility Wrapper
local function safeSpeak(text)
    pcall(function()
        if service and service.speak then
            service.speak(text)
        end
    end)
end

-- Load Data from SharedPreferences Safely
local function loadPreferencesData()
    safeCall(function()
        local fav_str = prefs.getString("favorites", "[]")
        local f_status, f_res = pcall(cjson.decode, fav_str)
        favorites_list = f_status and f_res or {}

        local hist_str = prefs.getString("history", "[]")
        local h_status, h_res = pcall(cjson.decode, hist_str)
        history_list = h_status and h_res or {}
        
        local shist_str = prefs.getString("search_history", "[]")
        local sh_status, sh_res = pcall(cjson.decode, shist_str)
        search_history_list = sh_status and sh_res or {}
    end)
end

local function saveFavorites()
    safeCall(function() editor.putString("favorites", cjson.encode(favorites_list)).apply() end)
end

local function saveHistory()
    safeCall(function() editor.putString("history", cjson.encode(history_list)).apply() end)
end

local function saveSearchHistory()
    safeCall(function() editor.putString("search_history", cjson.encode(search_history_list)).apply() end)
end

local function addToHistory(channel)
    safeCall(function()
        if not channel or not channel.id then return end
        for i, v in ipairs(history_list) do
            if v.id == channel.id then
                table.remove(history_list, i)
                break
            end
        end
        table.insert(history_list, 1, channel)
        if #history_list > 50 then table.remove(history_list) end
        saveHistory()
    end)
end

local function addToSearchHistory(query)
    if not query or query == "" then return end
    safeCall(function()
        for i, v in ipairs(search_history_list) do
            if v == query then
                table.remove(search_history_list, i)
                break
            end
        end
        table.insert(search_history_list, 1, query)
        if #search_history_list > 30 then table.remove(search_history_list) end
        saveSearchHistory()
    end)
end

local function isFavorite(channel_id)
    for i, v in ipairs(favorites_list) do
        if v == channel_id then return true, i end
    end
    return false, 0
end

local function setCountry(country_name)
    current_country = country_name or "All Countries"
    editor.putString("last_country", current_country).apply()
    if btn_country then btn_country.setText("Country: " .. current_country) end
    if search_runnable then search_runnable.run() end
end

local function setCategory(category_name)
    current_category = category_name or "All Categories"
    if btn_category then btn_category.setText("Category: " .. current_category) end
    if search_runnable then search_runnable.run() end
end

-- User Interest & Recommendation Engine Algorithm
local function getUserInterestWeights()
    local cat_weights = {}
    local country_weights = {}
    safeCall(function()
        for _, item in ipairs(history_list) do
            if item.category then cat_weights[item.category] = (cat_weights[item.category] or 0) + 1 end
            if item.country then country_weights[item.country] = (country_weights[item.country] or 0) + 1 end
        end
    end)
    return cat_weights, country_weights
end

local function calculateChannelScore(channel, cat_weights, country_weights)
    local score = 0
    safeCall(function()
        if channel.category and cat_weights[channel.category] then score = score + (cat_weights[channel.category] * 10) end
        if channel.country and country_weights[channel.country] then score = score + (country_weights[channel.country] * 5) end
        if isFavorite(channel.id) then score = score + 20 end
    end)
    return score
end

-- Main Layout Setup
local main_layout = {
    LinearLayout,
    orientation = "vertical",
    layout_width = "fill",
    layout_height = "fill",
    background = "#121212",
    {
        TextView,
        text = "Live television channel player by YouTube production studio",
        textSize = "22sp",
        textColor = "#00d4ff",
        layout_width = "fill",
        gravity = "center",
        padding = "10dp",
        background = "#1e1e1e",
    },
    {
        TextView,
        text = "Developed by Muhammad Hussain",
        textSize = "14sp",
        textColor = "#aaaaaa",
        layout_width = "fill",
        gravity = "center",
        paddingBottom = "10dp",
        background = "#1e1e1e",
    },
    {
        TextView,
        id = "tv_channel_count",
        text = "Loaded Channels: 0",
        textSize = "14sp",
        textColor = "#aaaaaa",
        layout_width = "fill",
        gravity = "center",
        paddingBottom = "5dp",
        background = "#1e1e1e",
    },
    {
        HorizontalScrollView,
        layout_width = "fill",
        horizontalScrollBarEnabled = false,
        background = "#1e1e1e",
        {
            LinearLayout,
            orientation = "horizontal",
            padding = "5dp",
            { Button, id = "btn_country", text = "Country: " .. current_country, onClick = function() showCountryDialog() end },
            { Button, id = "btn_category", text = "Category: " .. current_category, onClick = function() showCategoryDialog() end },
            { Button, id = "btn_fav_toggle", text = "View Favourite Channels", onClick = function() showFavoritesDialog() end },
            { Button, id = "btn_history", text = "View Watch History", onClick = function() showHistoryDialog() end },
            { Button, id = "btn_search_history", text = "View Search History", onClick = function() showSearchHistoryDialog() end },
            { Button, id = "btn_refresh", text = "Refresh", onClick = function() fetchChannelsData() end }
        }
    },
    {
        LinearLayout,
        orientation = "horizontal",
        layout_width = "fill",
        padding = "10dp",
        gravity = "center_vertical",
        {
            EditText,
            id = "search_box",
            hint = "Search Channels Only...",
            textColor = "#ffffff",
            hintTextColor = "#888888",
            layout_weight = 1,
            padding = "12dp",
            inputType = InputType.TYPE_CLASS_TEXT,
            singleLine = true,
        },
        {
            Button,
            id = "btn_voice_search",
            text = "Voice Search",
            textSize = "14sp",
            layout_width = "wrap",
            onClick = function() startVoiceSearch() end
        }
    },
    -- Loading Screen with Progress Bar
    {
        LinearLayout,
        id = "loading_layout",
        orientation = "vertical",
        layout_width = "fill",
        layout_height = "fill",
        gravity = "center",
        padding = "20dp",
        {
            ProgressBar,
            id = "progress_bar",
            style = "?android:attr/progressBarStyleLarge",
        },
        {
            TextView,
            id = "tv_loading",
            text = "Initializing...",
            textColor = "#aaaaaa",
            textSize = "16sp",
            gravity = "center",
            paddingTop = "10dp",
        }
    },
    {
        ListView,
        id = "channel_list",
        layout_width = "fill",
        layout_height = "fill",
        dividerHeight = "1dp",
        visibility = View.GONE,
    }
}

this.setContentView(loadlayout(main_layout))

-- Adding icons programmatically
pcall(function()
    btn_country.setCompoundDrawablesWithIntrinsicBounds(android.R.drawable.ic_menu_mapmode, 0, 0, 0)
    btn_category.setCompoundDrawablesWithIntrinsicBounds(android.R.drawable.ic_menu_sort_by_size, 0, 0, 0)
    btn_fav_toggle.setCompoundDrawablesWithIntrinsicBounds(android.R.drawable.ic_menu_star, 0, 0, 0)
    btn_history.setCompoundDrawablesWithIntrinsicBounds(android.R.drawable.ic_menu_recent_history, 0, 0, 0)
    btn_search_history.setCompoundDrawablesWithIntrinsicBounds(android.R.drawable.ic_menu_search, 0, 0, 0)
    btn_refresh.setCompoundDrawablesWithIntrinsicBounds(android.R.drawable.ic_popup_sync, 0, 0, 0)
    btn_voice_search.setCompoundDrawablesWithIntrinsicBounds(android.R.drawable.ic_btn_speak_now, 0, 0, 0)

    local padding = 10
    btn_country.setCompoundDrawablePadding(padding)
    btn_category.setCompoundDrawablePadding(padding)
    btn_fav_toggle.setCompoundDrawablePadding(padding)
    btn_history.setCompoundDrawablePadding(padding)
    btn_search_history.setCompoundDrawablePadding(padding)
    btn_refresh.setCompoundDrawablePadding(padding)
    btn_voice_search.setCompoundDrawablePadding(padding)
end)

-- Main Channel List Adapter
local list_adapter = LuaAdapter(this, {
    LinearLayout,
    orientation = "vertical",
    layout_width = "fill",
    padding = "15dp",
    {
        TextView,
        id = "tv_name",
        textSize = "18sp",
        textColor = "#ffffff",
    },
    {
        TextView,
        id = "tv_meta",
        textSize = "14sp",
        textColor = "#888888",
    }
})
channel_list.setAdapter(list_adapter)

local function updateChannelList(data, is_recommendation)
    safeCall(function()
        filtered_channels = data or {}
        list_adapter.clear()
        
        if is_recommendation then
            tv_channel_count.setText("No Match Found | Recommended Channels: " .. #filtered_channels)
        else
            tv_channel_count.setText("Loaded Channels: " .. #filtered_channels)
        end
        
        for i, channel in ipairs(filtered_channels) do
            local fav_indicator = isFavorite(channel.id) and "[FAV] " or ""
            
            -- Hide unknown languages
            local lang_str = ""
            if channel.language and channel.language ~= "" and string.lower(channel.language) ~= "unknown" then
                lang_str = " | Language: " .. channel.language
            end
            
            local meta_text = string.format("Country: %s | Category: %s%s", channel.country or "Unknown", channel.category or "General", lang_str)
            list_adapter.add({
                tv_name = fav_indicator .. (channel.name or "Unnamed Channel"),
                tv_meta = meta_text
            })
        end
        list_adapter.notifyDataSetChanged()
        
        if #filtered_channels == 0 then
            loading_layout.setVisibility(View.VISIBLE)
            progress_bar.setVisibility(View.GONE)
            tv_loading.setText("No channels match your filter.")
            channel_list.setVisibility(View.GONE)
        else
            loading_layout.setVisibility(View.GONE)
            channel_list.setVisibility(View.VISIBLE)
        end
    end)
end

-- Search & Smart Algorithm Logic
local search_handler = Handler()
search_runnable = Runnable({
    run = function()
        safeCall(function()
            local query = string.lower(search_box.getText().toString())
            
            if query ~= "" and string.len(query) >= 3 and query ~= last_saved_query then
                addToSearchHistory(query)
                last_saved_query = query
            end

            local results = {}
            local cat_weights, country_weights = getUserInterestWeights()
            
            for _, channel in ipairs(all_channels) do
                local match_country = (current_country == "All Countries" or (channel.country or "Unknown") == current_country)
                local match_cat = (current_category == "All Categories" or (channel.category or "General") == current_category)
                local match_name = (query == "" or string.find(string.lower(channel.name or ""), query, 1, true))

                if match_country and match_cat and match_name then
                    channel.score = calculateChannelScore(channel, cat_weights, country_weights)
                    table.insert(results, channel)
                end
            end
            
            if #results > 0 or query == "" then
                table.sort(results, function(a, b) return (a.score or 0) > (b.score or 0) end)
                updateChannelList(results, false)
            else
                local recommendations = {}
                for _, channel in ipairs(all_channels) do
                    local match_country = (current_country == "All Countries" or (channel.country or "Unknown") == current_country)
                    local match_cat = (current_category == "All Categories" or (channel.category or "General") == current_category)
                    
                    if match_country and match_cat then
                        channel.score = calculateChannelScore(channel, cat_weights, country_weights)
                        table.insert(recommendations, channel)
                    end
                end
                
                table.sort(recommendations, function(a, b) return (a.score or 0) > (b.score or 0) end)
                
                local final_rec = {}
                for i = 1, math.min(#recommendations, 50) do
                    table.insert(final_rec, recommendations[i])
                end
                updateChannelList(final_rec, true)
            end
        end)
    end
})

search_box.addTextChangedListener(TextWatcher({
    onTextChanged = function(c, start, before, count)
        search_handler.removeCallbacks(search_runnable)
        search_handler.postDelayed(search_runnable, 250) 
    end
}))

function startVoiceSearch()
    safeCall(function()
        local intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
        intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        intent.putExtra(RecognizerIntent.EXTRA_PROMPT, "Say a channel name...")
        this.startActivityForResult(intent, 100)
    end)
end

function onActivityResult(requestCode, resultCode, data)
    if requestCode == 100 and resultCode == Activity.RESULT_OK and data ~= nil then
        safeCall(function()
            local result = data.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
            if result and result.size() > 0 then
                search_box.setText(result.get(0))
            end
        end)
    end
end

function fetchChannelsData()
    loading_layout.setVisibility(View.VISIBLE)
    channel_list.setVisibility(View.GONE)
    progress_bar.setVisibility(View.VISIBLE)
    tv_loading.setText("Downloading streams data...")
    
    all_channels = {}
    stream_map = {}
    
    local country_set = {}
    all_countries = {}
    local category_set = {["All Categories"] = true}
    all_categories = {"All Categories"}
    
    Http.get("https://iptv-org.github.io/api/streams.json", function(code, content)
        if code == 200 and content then
            tv_loading.setText("Processing streams... Please wait.")
            Handler().postDelayed(Runnable({
                run = function()
                    local s_status, streams_data = safeCall(cjson.decode, content)
                    if s_status and type(streams_data) == "table" then
                        safeCall(function()
                            for i, stream in ipairs(streams_data) do
                                if stream and stream.channel and stream.url then 
                                    if not stream_map[stream.channel] then
                                        stream_map[stream.channel] = {}
                                    end
                                    table.insert(stream_map[stream.channel], {
                                        url = stream.url,
                                        quality = stream.quality or "",
                                        feed = stream.feed or "",
                                        user_agent = stream.user_agent or "",
                                        referrer = stream.referrer or "",
                                        status = stream.status or ""
                                    })
                                end
                            end
                        end)
                        
                        tv_loading.setText("Downloading channels data...")
                        Http.get("https://iptv-org.github.io/api/channels.json", function(c_code, c_content)
                            if c_code == 200 and c_content then
                                tv_loading.setText("Processing channels... Almost done!")
                                Handler().postDelayed(Runnable({
                                    run = function()
                                        local c_status, c_data = safeCall(cjson.decode, c_content)
                                        if c_status and type(c_data) == "table" then
                                            safeCall(function()
                                                for i, channel in ipairs(c_data) do
                                                    if channel and channel.id and stream_map[channel.id] then
                                                        
                                                        local c_country = "Unknown"
                                                        if channel.country and channel.country ~= "" then
                                                            local loc = Locale("", string.upper(channel.country))
                                                            c_country = loc.getDisplayCountry()
                                                            if not c_country or c_country == "" then c_country = string.upper(channel.country) end
                                                        end
                                                        
                                                        local c_cat = "General"
                                                        if channel.categories and type(channel.categories)=="table" and #channel.categories > 0 then
                                                            c_cat = channel.categories[1]:gsub("^%l", string.upper)
                                                        end

                                                        local c_lang = "Unknown"
                                                        if channel.languages and type(channel.languages)=="table" and #channel.languages > 0 then
                                                            c_lang = channel.languages[1]:gsub("^%l", string.upper)
                                                        end
                                                        
                                                        table.insert(all_channels, {
                                                            id = channel.id,
                                                            name = channel.name or "Unnamed",
                                                            country = c_country,
                                                            category = c_cat,
                                                            language = c_lang,
                                                            logo = channel.logo or "",
                                                            streams = stream_map[channel.id]
                                                        })
                                                        
                                                        if not country_set[c_country] then
                                                            country_set[c_country] = true
                                                            table.insert(all_countries, c_country)
                                                        end
                                                        if not category_set[c_cat] then
                                                            category_set[c_cat] = true
                                                            table.insert(all_categories, c_cat)
                                                        end
                                                    end
                                                end
                                            end)
                                            table.sort(all_countries)
                                            table.insert(all_countries, 1, "All Countries")
                                            table.sort(all_categories)
                                            
                                            loading_layout.setVisibility(View.GONE)
                                            channel_list.setVisibility(View.VISIBLE)
                                            search_runnable.run()
                                        else
                                            progress_bar.setVisibility(View.GONE)
                                            tv_loading.setText("Channel data loaded, but metadata is unavailable.")
                                        end
                                    end
                                }), 5) 
                            else
                                progress_bar.setVisibility(View.GONE)
                                tv_loading.setText("Channel data API failure. Continuing with stream data only if possible.")
                            end
                        end)
                    else
                        progress_bar.setVisibility(View.GONE)
                        tv_loading.setText("Failed to parse streams data. Format error.")
                    end
                end
            }), 5)
        else
            progress_bar.setVisibility(View.GONE)
            tv_loading.setText("Network error fetching streams. Please check internet.")
        end
    end)
end

-- Country Dialog
function showCountryDialog()
    local env = {}
    local dialog_layout = {
        LinearLayout, orientation="vertical", layout_width="fill", padding="10dp",
        { EditText, id="search_country_box", hint="Search Country...", layout_width="fill", padding="10dp" },
        { ListView, id="country_list", layout_width="fill", layout_height="400dp" }
    }
    
    local c_dialog = LuaDialog(this).setTitle("Select Country").setView(loadlayout(dialog_layout, env))
    c_dialog.setNegativeButton("Cancel", DialogInterface.OnClickListener{ onClick = function() c_dialog.dismiss() end })
    c_dialog.show()

    local c_adapter = LuaAdapter(this, { LinearLayout, layout_width="fill", padding="15dp", { TextView, id="c_name", textSize="18sp", textColor="#333333" }})
    env.country_list.setAdapter(c_adapter)
    
    local filtered_c_list = {}
    local function populateCountries(query)
        c_adapter.clear()
        filtered_c_list = {}
        query = string.lower(query or "")
        
        for _, c in ipairs(all_countries) do
            if query == "" or string.find(string.lower(c), query, 1, true) then
                table.insert(filtered_c_list, c)
                c_adapter.add({ c_name = c })
            end
        end
        c_adapter.notifyDataSetChanged()
    end
    
    populateCountries("")
    env.search_country_box.addTextChangedListener(TextWatcher({ onTextChanged = function(c, start, before, count) populateCountries(env.search_country_box.getText().toString()) end }))
    env.country_list.setOnItemClickListener(AdapterView.OnItemClickListener{ onItemClick = function(parent, view, position, id)
        local selected = filtered_c_list[position + 1]
        if selected then setCountry(selected); c_dialog.dismiss() end
    end})
end

-- Category Dialog
function showCategoryDialog()
    local env = {}
    local dialog_layout = {
        LinearLayout, orientation="vertical", layout_width="fill", padding="10dp",
        { EditText, id="search_cat_box", hint="Search Category...", layout_width="fill", padding="10dp" },
        { ListView, id="cat_list", layout_width="fill", layout_height="400dp" }
    }
    
    local cat_dialog = LuaDialog(this).setTitle("Select Category").setView(loadlayout(dialog_layout, env))
    cat_dialog.setNegativeButton("Cancel", DialogInterface.OnClickListener{ onClick = function() cat_dialog.dismiss() end })
    cat_dialog.show()

    local cat_adapter = LuaAdapter(this, { LinearLayout, layout_width="fill", padding="15dp", { TextView, id="cat_name", textSize="18sp", textColor="#333333" }})
    env.cat_list.setAdapter(cat_adapter)
    
    local filtered_cat_list = {}
    local function populateCategories(query)
        cat_adapter.clear()
        filtered_cat_list = {}
        query = string.lower(query or "")
        for _, c in ipairs(all_categories) do
            if query == "" or string.find(string.lower(c), query, 1, true) then
                table.insert(filtered_cat_list, c)
                cat_adapter.add({ cat_name = c })
            end
        end
        cat_adapter.notifyDataSetChanged()
    end
    
    populateCategories("")
    env.search_cat_box.addTextChangedListener(TextWatcher({ onTextChanged = function(c, start, before, count) populateCategories(env.search_cat_box.getText().toString()) end }))
    env.cat_list.setOnItemClickListener(AdapterView.OnItemClickListener{ onItemClick = function(parent, view, position, id)
        local selected = filtered_cat_list[position + 1]
        if selected then setCategory(selected); cat_dialog.dismiss() end
    end})
end

-- Dedicated Favorites Dialog with Search Fixed
function showFavoritesDialog()
    local env = {}
    local dialog_layout = { 
        LinearLayout, 
        orientation="vertical", 
        layout_width="fill", 
        {
            TextView,
            text = "Controls Information:\n- Tap to play the channel directly.\n- Long press (hold) to remove from favorites.",
            textSize = "14sp",
            textColor = "#555555",
            padding = "10dp",
            background = "#f0f0f0"
        },
        {
            EditText,
            id = "search_fav_box",
            hint = "Search Favourites...",
            textColor = "#000000",
            layout_width = "fill",
            padding = "10dp",
            singleLine = true
        },
        { ListView, id="f_list", layout_width="fill", layout_weight=1, padding="5dp" } 
    }
    
    local f_adapter = LuaAdapter(this, { LinearLayout, orientation="vertical", layout_width="fill", padding="15dp", { TextView, id="t_name", textSize="16sp", textColor="#333333" }})
    
    local f_dialog = LuaDialog(this)
    f_dialog.setTitle("Your Favourite Channels")
    f_dialog.setView(loadlayout(dialog_layout, env))
    f_dialog.setNegativeButton("Close", DialogInterface.OnClickListener{ onClick = function() f_dialog.dismiss() end })
    f_dialog.show()
    
    env.f_list.setAdapter(f_adapter)
    
    local mapped_favorites = {}
    favorites_dialog_refresh = function(query)
        query = string.lower(query or "")
        f_adapter.clear()
        mapped_favorites = {}
        for _, fav_id in ipairs(favorites_list) do
            local fav_channel = nil
            for _, ch in ipairs(all_channels) do
                if ch.id == fav_id then
                    fav_channel = ch
                    break
                end
            end
            
            local name_to_search = fav_id
            local country_to_show = "Offline"
            if fav_channel then
                name_to_search = fav_channel.name
                country_to_show = fav_channel.country or "Unknown"
            end
            
            if query == "" or string.find(string.lower(name_to_search), query, 1, true) then
                if fav_channel then
                    table.insert(mapped_favorites, fav_channel)
                else
                    table.insert(mapped_favorites, {id=fav_id, name=fav_id, is_offline=true})
                end
                f_adapter.add({ t_name = name_to_search .. " (" .. country_to_show .. ")" })
            end
        end
        f_adapter.notifyDataSetChanged()
    end
    favorites_dialog_refresh("")

    env.search_fav_box.addTextChangedListener(TextWatcher({ 
        onTextChanged = function(c, start, before, count) 
            favorites_dialog_refresh(env.search_fav_box.getText().toString()) 
        end 
    }))
    
    env.f_list.setOnItemClickListener(AdapterView.OnItemClickListener{ onItemClick = function(parent, view, position, id)
        local fav_channel = mapped_favorites[position+1]
        if fav_channel and not fav_channel.is_offline then
            f_dialog.dismiss()
            launchPlayerUI(fav_channel, position + 1, mapped_favorites)
        else
            Toast.makeText(this, "Channel data offline.", Toast.LENGTH_SHORT).show()
        end
    end})
    
    env.f_list.setOnItemLongClickListener(AdapterView.OnItemLongClickListener{ onItemLongClick = function(parent, view, position, id)
        local item = mapped_favorites[position + 1]
        if item then
            for i, v in ipairs(favorites_list) do
                if v == item.id then
                    table.remove(favorites_list, i)
                    break
                end
            end
            saveFavorites()
            favorites_dialog_refresh(env.search_fav_box.getText().toString())
            search_runnable.run()
            Toast.makeText(this, "Removed from Favorites", Toast.LENGTH_SHORT).show()
        end
        return true
    end})
end

-- Watch History Dialog
function showHistoryDialog()
    local env = {}
    local dialog_layout = { 
        LinearLayout, 
        orientation="vertical", 
        layout_width="fill", 
        {
            TextView,
            text = "Controls Information:\n- Tap to play the channel again.\n- Long press (hold) to delete the channel permanently from history.",
            textSize = "14sp",
            textColor = "#555555",
            padding = "10dp",
            background = "#f0f0f0"
        },
        { ListView, id="h_list", layout_width="fill", layout_weight=1, padding="5dp" } 
    }
    local h_adapter = LuaAdapter(this, { LinearLayout, orientation="vertical", layout_width="fill", padding="15dp", { TextView, id="t_name", textSize="16sp", textColor="#333333" }})
    
    local h_dialog = LuaDialog(this)
    h_dialog.setTitle("Watch History")
    h_dialog.setView(loadlayout(dialog_layout, env))
    
    h_dialog.setPositiveButton("Clear All", {onClick = function() 
        history_list = {}
        saveHistory()
        Toast.makeText(this, "History Cleared", Toast.LENGTH_SHORT).show()
        search_runnable.run()
    end})
    h_dialog.setNegativeButton("Close", DialogInterface.OnClickListener{ onClick = function() h_dialog.dismiss() end })
    h_dialog.show()
    
    env.h_list.setAdapter(h_adapter)
    local function refreshHistoryUI()
        h_adapter.clear()
        for i, ch in ipairs(history_list) do h_adapter.add({ t_name = ch.name .. " (" .. (ch.country or "") .. ")" }) end
        h_adapter.notifyDataSetChanged()
    end
    refreshHistoryUI()
    
    env.h_list.setOnItemClickListener(AdapterView.OnItemClickListener{ onItemClick = function(parent, view, position, id)
        h_dialog.dismiss()
        launchPlayerUI(history_list[position+1], position+1, history_list)
    end})
    
    env.h_list.setOnItemLongClickListener(AdapterView.OnItemLongClickListener{ onItemLongClick = function(parent, view, position, id)
        local item_idx = position + 1
        local del_dialog = LuaDialog(this).setTitle("Delete Item?").setMessage("Remove this from history?")
        del_dialog.setPositiveButton("Yes", {onClick=function()
            table.remove(history_list, item_idx)
            saveHistory()
            refreshHistoryUI()
            search_runnable.run()
        end})
        del_dialog.setNegativeButton("No", DialogInterface.OnClickListener{ onClick = function() del_dialog.dismiss() end })
        del_dialog.show()
        return true
    end})
end

-- Search History Dialog
function showSearchHistoryDialog()
    local env = {}
    local dialog_layout = { 
        LinearLayout, 
        orientation="vertical", 
        layout_width="fill", 
        {
            TextView,
            text = "Controls Information:\n- Tap to search your query again.\n- Long press (hold) to copy text or delete from history.",
            textSize = "14sp",
            textColor = "#555555",
            padding = "10dp",
            background = "#f0f0f0"
        },
        { ListView, id="sh_list", layout_width="fill", layout_weight=1, padding="5dp" } 
    }
    local sh_adapter = LuaAdapter(this, { LinearLayout, orientation="vertical", layout_width="fill", padding="15dp", { TextView, id="t_query", textSize="16sp", textColor="#333333" }})

    local sh_dialog = LuaDialog(this)
    sh_dialog.setTitle("Search History")
    sh_dialog.setView(loadlayout(dialog_layout, env))
    
    sh_dialog.setPositiveButton("Clear All", {onClick = function()
        search_history_list = {}
        saveSearchHistory()
        Toast.makeText(this, "Search History Cleared", Toast.LENGTH_SHORT).show()
    end})
    sh_dialog.setNegativeButton("Close", DialogInterface.OnClickListener{ onClick = function() sh_dialog.dismiss() end })
    sh_dialog.show()

    env.sh_list.setAdapter(sh_adapter)
    local function refreshSearchUI()
        sh_adapter.clear()
        for i, q in ipairs(search_history_list) do
            sh_adapter.add({ t_query = q })
        end
        sh_adapter.notifyDataSetChanged()
    end
    refreshSearchUI()

    env.sh_list.setOnItemClickListener(AdapterView.OnItemClickListener{ onItemClick = function(parent, view, position, id)
        sh_dialog.dismiss()
        search_box.setText(search_history_list[position+1])
    end})

    env.sh_list.setOnItemLongClickListener(AdapterView.OnItemLongClickListener{ onItemLongClick = function(parent, view, position, id)
        local item_idx = position + 1
        local query_text = search_history_list[item_idx]
        
        local manage_dialog = LuaDialog(this)
        manage_dialog.setTitle("Manage Search History")
        manage_dialog.setMessage("Query: " .. query_text)
        
        manage_dialog.setPositiveButton("Delete", {onClick=function()
            table.remove(search_history_list, item_idx)
            saveSearchHistory()
            refreshSearchUI()
            Toast.makeText(this, "Deleted from history", Toast.LENGTH_SHORT).show()
        end})
        
        manage_dialog.setNeutralButton("Copy", {onClick=function()
            local clipboard = this.getSystemService(Context.CLIPBOARD_SERVICE)
            local clip = ClipData.newPlainText("Search Query", query_text)
            clipboard.setPrimaryClip(clip)
            Toast.makeText(this, "Copied to clipboard!", Toast.LENGTH_SHORT).show()
        end})
        
        manage_dialog.setNegativeButton("Cancel", {onClick=function() end})
        manage_dialog.show()
        return true
    end})
end

-- Sleep Timer Dialog
local sleep_handler = Handler()
local sleep_runnable = Runnable({
    run = function()
        safeCall(function()
            releasePlayer()
            if player_dialog then player_dialog.dismiss() end
            Toast.makeText(this, "Sleep Timer finished. Playback stopped.", Toast.LENGTH_LONG).show()
        end)
    end
})

function showSleepTimerDialog()
    local options = {"15 Minutes", "30 Minutes", "60 Minutes", "Cancel Timer"}
    local times = {15, 30, 60, 0}
    local builder = AlertDialog.Builder(this)
    builder.setTitle("Set Sleep Timer")
    builder.setItems(options, DialogInterface.OnClickListener{
        onClick = function(dialog, which)
            local mins = times[which + 1]
            sleep_handler.removeCallbacks(sleep_runnable)
            if mins > 0 then
                sleep_handler.postDelayed(sleep_runnable, mins * 60 * 1000)
                Toast.makeText(this, "Timer set for " .. mins .. " minutes", Toast.LENGTH_SHORT).show()
            else
                Toast.makeText(this, "Sleep Timer Cancelled", Toast.LENGTH_SHORT).show()
            end
        end
    })
    builder.setNegativeButton("Cancel", DialogInterface.OnClickListener{ onClick = function() end })
    builder.show()
end

function showQualityDialog()
    local qualities = {"Auto (Best Quality)", "1080p (Full HD)", "720p (HD)", "480p (SD)", "360p (Data Saver)", "Digital Mic Mode"}
    local builder = AlertDialog.Builder(this)
    builder.setTitle("Select Stream & Audio Quality")
    builder.setItems(qualities, DialogInterface.OnClickListener{
        onClick = function(dialog, which)
            local sel = qualities[which + 1]
            current_quality_setting = sel
            Toast.makeText(this, "Applying Quality: " .. sel, Toast.LENGTH_SHORT).show()
            
            if dialog_env and dialog_env.tv_player_status and current_stream_channel then
                dialog_env.tv_player_status.setText("Applying Quality [" .. sel .. "]...")
                releasePlayer()
                Handler().postDelayed(Runnable({
                    run = function()
                        if current_stream_channel then
                            startPlaybackSession(current_stream_channel, true)
                        end
                    end
                }), 500)
            end
        end
    })
    builder.setNegativeButton("Cancel", DialogInterface.OnClickListener{ onClick = function() end })
    builder.show()
end

-- Video Player Layout
local player_layout = {
    LinearLayout, orientation="vertical", layout_width="fill", layout_height="fill", background="#000000",
    { TextView, id="tv_player_status", text="Initializing...", textColor="#ffffff", padding="10dp", gravity="center", layout_width="fill" },
    { FrameLayout, layout_width="fill", layout_weight=1,
      { VideoView, id="video_view", layout_width="fill", layout_height="wrap", layout_gravity="center" },
      { LinearLayout, id="audio_only_overlay", layout_width="fill", layout_height="fill", background="#000000", visibility=View.GONE, gravity="center",
        { TextView, text="Audio Only Mode Enabled\nVideo is hidden to save data and battery", textColor="#aaaaaa", textSize="16sp", gravity="center" }
      }
    },
    -- Volume Slider Control
    { LinearLayout, orientation="horizontal", layout_width="fill", padding="10dp", gravity="center_vertical",
      { TextView, text="馃攰 ", textColor="#ffffff", textSize="16sp", paddingRight="5dp" },
      { SeekBar, id="volume_seekbar", layout_width="fill", layout_weight=1 }
    },
    -- Full Screen & Audio Only Checkboxes
    { LinearLayout, orientation="horizontal", layout_width="fill", padding="5dp", gravity="center",
      { CheckBox, id="cb_fullscreen", text="Play in Landscape", textColor="#ffffff", textSize="14sp", layout_weight=1 },
      { CheckBox, id="cb_audio_only", text="Play Only Audio", textColor="#ffffff", textSize="14sp", layout_weight=1 }
    },
    -- Completed Button Names & ScrollView
    { HorizontalScrollView, layout_width="fill", horizontalScrollBarEnabled=false,
      { LinearLayout, orientation="horizontal", layout_width="fill", padding="10dp", gravity="center",
        { Button, id="btn_player_fav", text="Add to Favorites" },
        { Button, id="btn_player_mute", text="Mute Audio" },
        { Button, text="Previous Channel", onClick=function() playAdjacentChannel(-1) end },
        { Button, text="Next Channel", onClick=function() playAdjacentChannel(1) end },
        { Button, text="Sleep Timer", onClick=function() showSleepTimerDialog() end },
        { Button, text="Change Quality", onClick=function() showQualityDialog() end },
        { Button, text="Close Player", onClick=function() if player_dialog then player_dialog.dismiss() end end }
      }
    }
}

player_dialog = nil
dialog_env = {} 

function releasePlayer()
    current_playback_session = current_playback_session + 1
    player_timeout_handler.removeCallbacksAndMessages(nil)
    
    safeCall(function()
        if dialog_env and dialog_env.video_view then
            dialog_env.video_view.stopPlayback()
            dialog_env.video_view.suspend()
        end
    end)
end

local max_fallback_retries = 3
local fallback_uas = {
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
    "VLC/3.0.18 LibVLC/3.0.18",
    "ExoPlayerDemo/2.18.1 (Linux; Android 12) ExoPlayerLib/2.18.1"
}

function executeStreamAttempt(channel, stream_list, stream_idx, fallback_idx, session_id)
    if session_id ~= current_playback_session then return end
    
    if not stream_list or #stream_list == 0 then
        if dialog_env and dialog_env.tv_player_status then
            dialog_env.tv_player_status.setText("This channel is currently overloaded or offline. No valid streams found.")
        end
        safeSpeak("No valid streams found.")
        return
    end
    
    if stream_idx > #stream_list then
        if fallback_idx < max_fallback_retries then
            executeStreamAttempt(channel, stream_list, 1, fallback_idx + 1, session_id)
        else
            if dialog_env and dialog_env.tv_player_status then
                dialog_env.tv_player_status.setText("Unable to play this channel. All available streams failed.")
            end
            safeSpeak("All available streams failed.")
        end
        return
    end
    
    local current_stream = stream_list[stream_idx]
    
    safeCall(function()
        local clean_url = string.gsub(current_stream.url, "^%s*(.-)%s*$", "%1")
        
        if fallback_idx == 1 then
            clean_url = string.gsub(clean_url, "^http://", "https://")
        elseif fallback_idx == 2 then
            clean_url = string.gsub(clean_url, "^https://", "http://")
        end

        local q_info = current_quality_setting ~= "Auto (Best Quality)" and (" | " .. current_quality_setting) or ""
        local attempt_info = ""
        if stream_idx > 1 or fallback_idx > 0 then
            attempt_info = string.format(" (Stream %d%s)", stream_idx, fallback_idx > 0 and ", Fix " .. fallback_idx or "")
        end
        
        dialog_env.tv_player_status.setText("Loading: " .. (channel.name or "Unknown") .. attempt_info .. q_info)
        
        if stream_idx > 1 or fallback_idx > 0 then
            safeSpeak(string.format("Trying alternative stream %d.", stream_idx))
        end
        
        local headers = HashMap()
        
        if fallback_idx == 0 and type(current_stream.user_agent) == "string" and current_stream.user_agent ~= "" then
            headers.put("User-Agent", current_stream.user_agent)
        elseif fallback_idx > 0 then
            headers.put("User-Agent", fallback_uas[fallback_idx] or fallback_uas[1])
        else
            headers.put("User-Agent", fallback_uas[1])
        end

        if type(current_stream.referrer) == "string" and current_stream.referrer ~= "" then
            headers.put("Referer", current_stream.referrer)
            headers.put("Origin", current_stream.referrer)
        end

        headers.put("Accept", "*/*")
        headers.put("Connection", "keep-alive")
        headers.put("Icy-MetaData", "1")
        
        dialog_env.video_view.setVideoURI(Uri.parse(clean_url), headers)
        local is_prepared = false
        
        dialog_env.video_view.setOnPreparedListener(MediaPlayer.OnPreparedListener{
            onPrepared = function(mp)
                if session_id ~= current_playback_session then return end
                is_prepared = true
                player_timeout_handler.removeCallbacksAndMessages(nil)
                
                dialog_env.current_mp = mp
                if dialog_env.is_muted then
                    mp.setVolume(0.0, 0.0)
                else
                    mp.setVolume(1.0, 1.0)
                end
                
                dialog_env.tv_player_status.setText("Playing: " .. (channel.name or "") .. q_info)
                safeSpeak("Playing " .. (channel.name or "channel"))
                
                pcall(function()
                    mp.setAudioStreamType(AudioManager.STREAM_MUSIC)
                    mp.setVideoScalingMode(MediaPlayer.VIDEO_SCALING_MODE_SCALE_TO_FIT) 
                    
                    local audioSession = mp.getAudioSessionId()
                    if audioSession and audioSession ~= 0 then
                        local enhancer = LoudnessEnhancer(audioSession)
                        if current_quality_setting == "Digital Mic Mode" then
                            enhancer.setTargetGain(1500) 
                            enhancer.setEnabled(true)
                        else
                            enhancer.setTargetGain(0) 
                            enhancer.setEnabled(false)
                        end
                    end
                end)
                
                dialog_env.video_view.start()
            end
        })
        
        dialog_env.video_view.setOnInfoListener(MediaPlayer.OnInfoListener{
            onInfo = function(mp, what, extra)
                 if session_id ~= current_playback_session then return false end
                 if what == MediaPlayer.MEDIA_INFO_BUFFERING_START then
                     dialog_env.tv_player_status.setText("Buffering: " .. (channel.name or ""))
                 elseif what == MediaPlayer.MEDIA_INFO_BUFFERING_END then
                     dialog_env.tv_player_status.setText("Playing: " .. (channel.name or "") .. q_info)
                 end
                 return false
            end
        })

        dialog_env.video_view.setOnErrorListener(MediaPlayer.OnErrorListener{
            onError = function(mp, what, extra)
                if session_id ~= current_playback_session then return true end
                player_timeout_handler.removeCallbacksAndMessages(nil)
                
                dialog_env.tv_player_status.setText("Stream failed. Trying next...")
                safeSpeak("Stream failed.")
                
                Handler().postDelayed(Runnable({
                    run = function()
                        executeStreamAttempt(channel, stream_list, stream_idx + 1, fallback_idx, session_id)
                    end
                }), 1000)
                
                return true
            end
        })

        player_timeout_handler.postDelayed(Runnable({
            run = function()
                if session_id == current_playback_session and not is_prepared then
                    dialog_env.tv_player_status.setText("Stream timed out. Switching...")
                    executeStreamAttempt(channel, stream_list, stream_idx + 1, fallback_idx, session_id)
                end
            end
        }), 15000) 
        
    end)
end

function startPlaybackSession(channel, is_quality_change)
    if not channel then return end
    current_stream_channel = channel
    
    if not is_quality_change then
        addToHistory(channel)
    end
    
    current_playback_session = current_playback_session + 1
    local session_id = current_playback_session
    
    local sorted_streams = {}
    if channel.streams and #channel.streams > 0 then
        for _, s in ipairs(channel.streams) do
            if current_quality_setting ~= "Auto (Best Quality)" and s.quality and string.find(string.lower(s.quality), string.lower(current_quality_setting)) then
                table.insert(sorted_streams, 1, s)
            else
                table.insert(sorted_streams, s)
            end
        end
    end
    
    executeStreamAttempt(channel, sorted_streams, 1, 0, session_id)
end

function playAdjacentChannel(offset)
    if current_playing_index ~= -1 and current_playlist and #current_playlist > 0 then
        local new_index = current_playing_index + offset
        if new_index >= 1 and new_index <= #current_playlist then
            current_playing_index = new_index
            current_quality_setting = "Auto (Best Quality)"
            releasePlayer()
            startPlaybackSession(current_playlist[new_index], false)
        else
            Toast.makeText(this, "No more channels in this direction", Toast.LENGTH_SHORT).show()
        end
    end
end

function launchPlayerUI(channel, list_index, context_list)
    safeCall(function()
        if context_list then current_playlist = context_list end
        if list_index then current_playing_index = list_index end
        
        current_quality_setting = "Auto (Best Quality)"
        
        dialog_env = {} 
        dialog_env.is_muted = false 
        dialog_env.current_mp = nil
        
        player_dialog = LuaDialog(this)
        .setView(loadlayout(player_layout, dialog_env))
        .setOnDismissListener(DialogInterface.OnDismissListener{
            onDismiss = function() 
                this.setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT)
                this.getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_VISIBLE)
                releasePlayer() 
            end
        })
        
        local isFav, _ = isFavorite(channel.id)
        dialog_env.btn_player_fav.setText(isFav and "Remove Favorite" or "Add to Favorites")
        
        dialog_env.btn_player_fav.onClick = function()
            local currentFav, index = isFavorite(channel.id)
            if currentFav then
                table.remove(favorites_list, index)
                dialog_env.btn_player_fav.setText("Add to Favorites")
                Toast.makeText(this, "Removed from Favorites", Toast.LENGTH_SHORT).show()
            else
                table.insert(favorites_list, channel.id)
                dialog_env.btn_player_fav.setText("Remove Favorite")
                Toast.makeText(this, "Added to Favorites", Toast.LENGTH_SHORT).show()
            end
            saveFavorites()
            if favorites_dialog_refresh and dialog_env.search_fav_box then
                favorites_dialog_refresh(dialog_env.search_fav_box.getText().toString())
            elseif favorites_dialog_refresh then 
                favorites_dialog_refresh("") 
            end
            search_runnable.run()
        end
        
        dialog_env.btn_player_mute.onClick = function()
            dialog_env.is_muted = not dialog_env.is_muted
            if dialog_env.current_mp then
                if dialog_env.is_muted then
                    dialog_env.current_mp.setVolume(0.0, 0.0)
                    dialog_env.btn_player_mute.setText("Unmute Audio")
                else
                    dialog_env.current_mp.setVolume(1.0, 1.0)
                    dialog_env.btn_player_mute.setText("Mute Audio")
                end
            else
                dialog_env.btn_player_mute.setText(dialog_env.is_muted and "Unmute Audio" or "Mute Audio")
            end
        end

        pcall(function()
            dialog_env.cb_fullscreen.setOnCheckedChangeListener(CompoundButton.OnCheckedChangeListener{
                onCheckedChanged = function(buttonView, isChecked)
                    if isChecked then
                        this.setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE)
                        this.getWindow().getDecorView().setSystemUiVisibility(
                            View.SYSTEM_UI_FLAG_FULLSCREEN | 
                            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | 
                            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        )
                    else
                        this.setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT)
                        this.getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_VISIBLE)
                    end
                end
            })
            
            dialog_env.cb_audio_only.setOnCheckedChangeListener(CompoundButton.OnCheckedChangeListener{
                onCheckedChanged = function(buttonView, isChecked)
                    if isChecked then
                        dialog_env.audio_only_overlay.setVisibility(View.VISIBLE)
                        Toast.makeText(this, "Audio Only Mode Enabled", Toast.LENGTH_SHORT).show()
                    else
                        dialog_env.audio_only_overlay.setVisibility(View.GONE)
                        Toast.makeText(this, "Audio Only Mode Disabled", Toast.LENGTH_SHORT).show()
                    end
                end
            })
        end)

        pcall(function()
            local audioManager = this.getSystemService(Context.AUDIO_SERVICE)
            local maxVol = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            local currentVol = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
            dialog_env.volume_seekbar.setMax(maxVol)
            dialog_env.volume_seekbar.setProgress(currentVol)
            dialog_env.volume_seekbar.setOnSeekBarChangeListener(SeekBar.OnSeekBarChangeListener{
                onProgressChanged = function(seekBar, progress, fromUser)
                    if fromUser then
                        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, progress, 0)
                    end
                end,
                onStartTrackingTouch = function(seekBar) end,
                onStopTrackingTouch = function(seekBar) end
            })
        end)

        player_dialog.show()
        startPlaybackSession(channel, false)
    end)
end

channel_list.setOnItemClickListener(AdapterView.OnItemClickListener{
    onItemClick = function(parent, view, position, id)
        local real_pos = position + 1
        launchPlayerUI(filtered_channels[real_pos], real_pos, filtered_channels)
    end
})

channel_list.setOnItemLongClickListener(AdapterView.OnItemLongClickListener{
    onItemLongClick = function(parent, view, position, id)
        safeCall(function()
            local channel = filtered_channels[position + 1]
            if not channel then return true end
            local isFav, index = isFavorite(channel.id)
            
            if isFav then
                table.remove(favorites_list, index)
                Toast.makeText(this, channel.name .. " removed from Favorites", Toast.LENGTH_SHORT).show()
                safeSpeak("Removed from favorites")
            else
                table.insert(favorites_list, channel.id)
                Toast.makeText(this, channel.name .. " added to Favorites", Toast.LENGTH_SHORT).show()
                safeSpeak("Added to favorites")
            end
            
            saveFavorites()
            search_runnable.run()
        end)
        return true
    end
})

local function checkFirstRun()
    if prefs.getBoolean("isFirstRun", true) then
        local first_dialog = LuaDialog(this)
        first_dialog.setTitle("Welcome to Live TV Player")
        first_dialog.setMessage("Features:\n- Advanced Multi-Stream Architecture.\n- Dedicated Favorites Control\n- Video Mute & Audio-Only Features.\n- Watch History & Sleep Timer.")
        first_dialog.setPositiveButton("Get Started", {onClick = function()
            editor.putBoolean("isFirstRun", false).apply()
        end})
        first_dialog.setNegativeButton("Cancel", DialogInterface.OnClickListener{ onClick = function() first_dialog.dismiss() end })
        first_dialog.show()
    end
end

loadPreferencesData()
checkFirstRun()
fetchChannelsData()
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

local baseUrl = "https://raw.githubusercontent.com/youtubeproductionstudio-web/live-television-player/main/"
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