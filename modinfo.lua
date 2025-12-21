version = "2.3.2"
name = "DST OST Remade "  .. version
-- borrowed from Uncomp (which borrowed from Island Adventures)
folder_name = folder_name or "workshop-"
if not folder_name:find("workshop-") then
    name = "[LOCAL] - " .. name
end

description = "Full sized expansion of Don't Starve Together music. Adds over an hour of new, original and fitting music with a lot of customization. Now with FULL Dusk and Night!"
author = "Adam 'Rampage' Ogrodnik"
forumthread = ""
api_version = 10

-- COMPATIBILITIES
dst_compatible = true
dont_starve_compatible = false
reign_of_giants_compatible = false
shipwrecked_compatible = false

all_clients_require_mod = false
client_only_mod = true
-- this one i came up with on my own
if client_only_mod and not all_clients_require_mod then
	name = name .. " [CLIENT]"
	else
	name = name .. " [SERVER]"
end

icon_atlas = "modicon.xml"
icon = "modicon.tex"

server_filter_tags = {
"music",
}

configuration_options = {
    {
        name = "rampage_musicstyle",
        label = "Soundtracks Shuffle",
        hover = "Choose whether you want to play with both soundtracks playing at 50/50, or just Remade OST.",
        options =
        {
            {description = "Yeah", data = false, hover = "You effectively get 2x more music. Intended experience."},
			{description = "Nah", data = true, hover = "Only the modded soundtrack will play."},
        },
        default = false,
    },
    {
        name = "dusk_and_night",
        label = "Enable Dusk & Night music?",
        hover = "Choose whether you want to play with remastered Dusk and Night music or not.",
        options =
        {
			{description = "Sure", data = true, hover = "Dusk and Night music will play during gameplay."},
            {description = "No, thanks", data = false, hover = "No music during dusks and nights."},
        },
        default = true,
	},
	{
        name = "continous",
        label = "Music Play Mode",
        hover = "Should the work music play contextually or continuosly?",
        options =
        {
		    {description = "Contextual", data = false, hover = "Music compliments your hard work. Intended experience."},
			{description = "Continuous", data = true, hover = "Work music plays constantly, save for fights. Use wisely."},
        },
        default = false,
	},
	{
		name = "enable_busy_music",
		label = "Enable modded work music? ",
		hover = "Toggle whether custom busy music during day should play.",
		options = {
			{description = "Yup", data = true, hover = "Modded busy soundtrack will play during day."},
			{description = "Uh-uh", data = false, hover = "Only vanilla soundtrack when working during day."},
		},
		default = true,
	},
	{
		name = "enable_danger_music",
		label = "Enable modded fight music?",
		hover = "Toggle whether custom danger music should play.",
		options = {
			{description = "Ok", data = true, hover = "Custom danger music will play during fights."},
			{description = "Naa", data = false, hover = "You won't hear custom danger music at all."}
		},
		default = true,
	},
	{
		name = "TOGGLE_KEY",
		label = "Music Pause Key",
		hover = "This key stops music for a while. Offers some break for your ears and mind.",
        options = {
            {description = "Numpad -", data = 269},
            {description = "F1", data = 282},
            {description = "F2", data = 283},
            {description = "F3", data = 284},
            {description = "F4", data = 285},
            {description = "F5", data = 286},
            {description = "F6", data = 287},
            {description = "F7", data = 288},
            {description = "F8", data = 289},
            {description = "F9", data = 290},
            {description = "F10", data = 291},
            {description = "F11", data = 292},
            {description = "F12", data = 293},
        },
        default = 269,
	},
}