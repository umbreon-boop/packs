--[=[
	Builds the icon pack sidecars consumed by Apogee's asset manager.

	Each archive stores PNG files by icon name in the `APGPK3` container and compresses
	the result as a Zstandard frame. The frame also stores the uncompressed bit length as
	a little-endian u32, matching Aria's `Vec.Decompress`.

	Every top-level folder in `resources/` becomes one pack with the same name. PNG and SVG
	folders both use their file names as icon names; SVG files are rendered to white
	transparent PNGs with ImageMagick.

	Usage:
		lune run build.luau [options] [pack...]

	Options:
		--resources <path>  Directory containing the icon source folders (default: resources)
		--output <path>     Directory for the generated .zst sidecars (default: packs)
		--cache <path>      Directory for rendered SVG PNGs (default: target/icon-renders)
		--size <px>         Rendered SVG size in pixels (default: 128)
		--jobs <n>          Parallel SVG render jobs (default: 4)
		--converter <cmd>   ImageMagick command used for SVG rendering (default: auto-detect)
		--help              Show this message
]=]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local task = require("@lune/task")

local MAGIC = "APGPK3"
local PNG_SIGNATURE = string.char(137) .. "PNG\r\n\26\n"

local function firstDirectory(paths, fallback)
	for _, path in paths do
		if fs.isDir(path) then
			return path
		end
	end
	return fallback
end

local options = {
	resources = firstDirectory({"resources", "../packs/resources"}, "resources"),
	output = firstDirectory({"packs", "../packs/packs", "../apogee/packs"}, "packs"),
	cache = "target/icon-renders",
	size = 128,
	jobs = 4,
	converter = nil,
}

local function usage()
	print([[
Builds Apogee icon pack sidecars.

Usage:
	lune run build.luau [options] [pack...]

Options:
	--resources <path>  Directory containing the icon source folders (default: resources)
	--output <path>     Directory for the generated .zst sidecars (default: packs)
	--cache <path>      Directory for rendered SVG PNGs (default: target/icon-renders)
	--size <px>         Rendered SVG size in pixels (default: 128)
	--jobs <n>          Parallel SVG render jobs (default: 4)
	--converter <cmd>   ImageMagick command used for SVG rendering (default: auto-detect)
	--help              Show this message
]])
end

local function optionValue(arguments, index, name)
	local argument = arguments[index]
	local prefix = name .. "="
	if string.sub(argument, 1, #prefix) == prefix then
		return string.sub(argument, #prefix + 1), index + 1
	end
	local value = arguments[index + 1]
	if value == nil then
		error(`Missing value for {name}`)
	end
	return value, index + 2
end

local selected = {}
local index = 1
while index <= #process.args do
	local argument = process.args[index]
	if argument == "--help" or argument == "-h" then
		usage()
		process.exit(0)
	elseif argument == "--resources" or string.sub(argument, 1, 12) == "--resources=" then
		options.resources, index = optionValue(process.args, index, "--resources")
	elseif argument == "--output" or string.sub(argument, 1, 9) == "--output=" then
		options.output, index = optionValue(process.args, index, "--output")
	elseif argument == "--cache" or string.sub(argument, 1, 8) == "--cache=" then
		options.cache, index = optionValue(process.args, index, "--cache")
	elseif argument == "--size" or string.sub(argument, 1, 7) == "--size=" then
		local value
		value, index = optionValue(process.args, index, "--size")
		options.size = tonumber(value) or error(`Invalid --size: {value}`)
	elseif argument == "--jobs" or string.sub(argument, 1, 7) == "--jobs=" then
		local value
		value, index = optionValue(process.args, index, "--jobs")
		options.jobs = math.max(1, tonumber(value) or error(`Invalid --jobs: {value}`))
	elseif argument == "--converter" or string.sub(argument, 1, 12) == "--converter=" then
		options.converter, index = optionValue(process.args, index, "--converter")
	elseif string.sub(argument, 1, 2) == "--" then
		error(`Unknown option: {argument}`)
	else
		selected[#selected + 1] = argument
		index += 1
	end
end

assert(fs.isDir(options.resources), `Resource directory not found: {options.resources}`)

if not options.converter then
	local ok, result = pcall(process.exec, "magick", {"-version"})
	if ok and result.ok then
		options.converter = "magick"
	else
		options.converter = "convert"
	end
end

local function discover(folder, extension)
	local path = `{options.resources}/{folder}`
	local files = {}
	if not fs.isDir(path) then
		warn(`Source folder not found: {path}`)
		return files
	end
	local seen = {}
	for _, name in fs.readDir(path) do
		if string.sub(name, -#extension) == extension then
			local stem = string.sub(name, 1, -#extension - 1)
			if seen[stem] then
				error(`{folder}: duplicate icon name {stem}`)
			end
			seen[stem] = true
			files[#files + 1] = {
				name = name,
				stem = stem,
				path = `{path}/{name}`,
			}
		end
	end
	table.sort(files, function(left, right)
		return left.stem < right.stem
	end)
	return files
end

local folders = {}
for _, name in fs.readDir(options.resources) do
	if fs.isDir(`{options.resources}/{name}`) then
		folders[#folders + 1] = name
	end
end
table.sort(folders)
assert(#folders > 0, `No icon folders found in {options.resources}`)

local plans = {}
for _, name in ipairs(folders) do
	local pngFiles = discover(name, ".png")
	local svgFiles = discover(name, ".svg")
	if #pngFiles > 0 and #svgFiles > 0 then
		error(`{name}: folder contains both PNG and SVG icons`)
	elseif #pngFiles > 0 then
		plans[#plans + 1] = {name = name, files = pngFiles}
	elseif #svgFiles > 0 then
		plans[#plans + 1] = {name = name, files = svgFiles}
	else
		warn(`{name}: no PNG or SVG icons found, skipping`)
	end
end

local byName = {}
for _, plan in ipairs(plans) do
	byName[plan.name] = plan
end

local requested = {}
for _, pack in ipairs(selected) do
	requested[pack] = true
end
local buildingAll = #selected == 0

-- Render every selected SVG once into the cache. The cache makes local rebuilds cheap
-- and is discarded automatically in CI.
local renderJobs = {}
for _, plan in ipairs(plans) do
	if buildingAll or requested[plan.name] then
		for _, file in ipairs(plan.files) do
			if string.sub(file.name, -4) == ".svg" then
				file.output = `{options.cache}/{plan.name}/{file.stem}.png`
				if not fs.isFile(file.output) then
					renderJobs[#renderJobs + 1] = {
						pack = plan.name,
						input = file.path,
						output = file.output,
					}
				end
			end
		end
	end
end

local function render(job)
	fs.writeDir(string.match(job.output, "^(.*)/[^/]+$"))
	local result = process.exec(options.converter, {
		"-background", "none",
		"-density", "384",
		job.input,
		"-resize", `{options.size}x{options.size}`,
		"-alpha", "extract",
		"-write", "mpr:mask",
		"+delete",
		"-size", `{options.size}x{options.size}`,
		"xc:white",
		"mpr:mask",
		"-alpha", "off",
		"-compose", "CopyOpacity",
		"-composite",
		job.output,
	})
	if not result.ok then
		error(`{job.input}: {result.stderr}`)
	end
end

if #renderJobs > 0 then
	print(`Rendering {#renderJobs} SVG icon(s) with {options.converter}`)
	local nextJob = 1
	local completed = 0
	local failures = {}
	local function worker()
		while true do
			local jobIndex = nextJob
			nextJob += 1
			local job = renderJobs[jobIndex]
			if not job then
				return
			end
			local ok, message = pcall(render, job)
			if not ok then
				failures[#failures + 1] = tostring(message)
			end
			completed += 1
			if completed % 500 == 0 or completed == #renderJobs then
				print(`Rendered {completed}/{#renderJobs}`)
			end
		end
	end
	for _ = 1, math.min(options.jobs, #renderJobs) do
		task.spawn(worker)
	end
	while completed < #renderJobs do
		task.wait()
	end
	if #failures > 0 then
		error(`Failed to render {#failures} icon(s):\n{table.concat(failures, "\n", 1, math.min(#failures, 10))}`)
	end
end

local function buildPack(plan)
	local entries = {}
	for _, file in ipairs(plan.files) do
		local path = file.output or file.path
		local data = fs.readFile(path)
		if string.sub(data, 1, #PNG_SIGNATURE) ~= PNG_SIGNATURE then
			error(`{plan.name}: {file.name} is not a PNG image`)
		end
		entries[#entries + 1] = {name = file.stem .. ".png", data = data}
	end

	local parts = {MAGIC, string.pack("<I4", #entries)}
	for _, entry in entries do
		local name = entry.name
		if #name > 0xFFFF then
			error(`{plan.name}: invalid archive filename {name}`)
		end
		parts[#parts + 1] = string.pack("<I2I4", #name, #entry.data)
		parts[#parts + 1] = name
		parts[#parts + 1] = entry.data
	end
	local payload = table.concat(parts)
	local bitLength = #payload * 8
	if bitLength > 0xFFFFFFFF then
		error(`{plan.name}: archive exceeds the maximum Vec payload size`)
	end

	local compressed = serde.compress("zstd", string.pack("<I4", bitLength) .. payload)
	fs.writeDir(options.output)
	local archive = `{options.output}/{plan.name}.zst`
	fs.writeFile(archive, compressed)
	return archive, #compressed
end

local packs = selected
if #packs == 0 then
	for _, plan in ipairs(plans) do
		packs[#packs + 1] = plan.name
	end

	-- A folder removal should remove its published sidecar as well.
	if fs.isDir(options.output) then
		for _, file in fs.readDir(options.output) do
			if string.sub(file, -4) == ".zst" then
				local pack = string.sub(file, 1, -5)
				if not byName[pack] then
					fs.removeFile(`{options.output}/{file}`)
					print(`removed {options.output}/{file}`)
				end
			end
		end
	end
end

for _, pack in packs do
	local plan = byName[pack]
	assert(plan, `Unknown pack: {pack}`)
	local archive, size = buildPack(plan)
	print(`{archive}: {size} bytes`)
end
