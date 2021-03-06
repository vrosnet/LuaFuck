-- using semantic versioning
local version = {
    major = 0,
    minor = 2,
    patch = 0
}
--function version.toString()
--    return "v"..version.major.."."..version.minor.."."..version.patch.."-Dagobah"
--end
setmetatable(version, {__tostring = function()
    return "v"..version.major.."."..version.minor.."."..version.patch.."-Dagobah"
    --this is kinda a lazy way of doing it..it really should just access itself somehow
end})

-- help output
local help = [[
NAME
    luafuck.lua - Compiles Brainfuck code into Lua code.

SYNOPSIS
    lua luafuck.lua [IN_FILE] [OPTIONS]

    (Note: OPTIONS must be specified individually.
     `-vds` won't work for example.)

DESCRIPTION
    Compiles Brainfuck into Lua code.

OPTIONS
    -v, --version
        output version
    -V, --verbose
        verbose output
    -d, --debug
        debug statements will be placed in the output code printing changes to
        the state of the program while it runs
    -o filename, --out=filename
        output filename to use (will append .lua to it if you don't)
    -e extension1 extension2, --extensions=extension1,extension2
        a list of extensions to enable
        (note: only the --extensions= form is supported right now!)
    -h, --help
        show this help

EXTENSIONS
    debug
        Adds # and ! instructions.
        # prints out the first 10 memory cells, and 9 memory cells surrounding
          the currently selected memory cell.
        ! makes the rest of the file get placed into the input buffer. (Instead
          of reading from keyboard.)
]]

-- extra start code to support direct translation of instructions
local bootstrap = {
    --TODO check if then can be condensed further by eliminating spaces after instances of "()"
    core = {
        default = "local c,m,o,w,i,b,r=0,{},string.char,io.write,string.byte,'',0",
        debug = "local c,m,o,w,i,b,r,t=0,{},string.char,io.write,string.byte,'',0,0"
    },
    input = {
        default = "r=function() if b:len()==0 then b=io.read() end local o=b:sub(1,1) b=b:sub(2) return o end",
        -- this debug is the extension, the other debugs are --debug option
        debug = "r=function() if b:len()==0 then return '' end local o=b:sub(1,1) b=b:sub(2) return o end local function M()"
    },
    post = {
        default = "setmetatable(m,{__index=function() return 0 end})"
    }
}

-- direct translations of instructions to Lua (with some tweaks)
local instructions = {
    core = {
        default = {
            [">"] = "c=c+1",
            ["<"] = "c=c-1",
            ["+"] = "m[c]=m[c]+1",
            ["-"] = "m[c]=m[c]-1",
            ["."] = "w(o(m[c]))",
            [","] = "m[c]=i(r())",
            ["["] = "while m[c]~=0 do",
            ["]"] = "end"
        },
        debug = {
            [">"] = "c=c+1 print('POINTER++: '..(c-1)..' => '..c)",
            ["<"] = "c=c-1 print('POINTER--: '..(c+1)..' => '..c)",
            ["+"] = "t=m[c] m[c]=m[c]+1 w('CELL++:    ')",
            ["-"] = "t=m[c] m[c]=m[c]-1 w('CELL--:    ')",
            ["."] = "t=o(m[c]) w(t) if t==nil then t='nil' end print('PRINT: '..m[c]..' # '..t)",
            [","] = "t=r() m[c]=i(t) if t==nil then t='nil' end print('READ: '..t..' => '..m[c])",
            ["["] = "print('WHILE NOT 0: START?\\nVALUE: '..m[c]) while m[c]~=0 do print('VALUE: '..m[c]..'\\nWHILE NOT 0: RUNNING')",
            ["]"] = "end print('WHILE NOT 0: OVER')"
        },
        optimized = {
            --TODO modify main loop to fall back on a failed match to this, so that
            -- the other commands still work without having to check here
            [">"] = "c=c+",
            ["<"] = "c=c-",
            ["+"] = "m[c]=m[c]+",
            ["-"] = "m[c]=m[c]-"
        }
    },
    post = {
        default = {
            ["+"] = "if m[c]>255 then m[c]=0 end",
            ["-"] = "if m[c]<0 then m[c]=255 end"
        },
        debug = {
            ["+"] = "if m[c]>255 then m[c]=0 end print(t..' => '..m[c])",
            ["-"] = "if m[c]<0 then m[c]=255 end print(t..' => '..m[c])"
        },
        optimized = {
            ["+"] = "while m[c]>255 do m[c]=m[c]-256 end",
            ["-"] = "while m[c]<0 do m[c]=m[c]+256 end"
        },
    },
    extend = {
        debug = {
            ["#"] = "for i=0,9 do w('m['..c..']='..m[c]..',') end w('\\n') for i=c-4,c+4 do w('m['..i..']='..m[i]..',') end",
            ["!"] = "end b='" -- we have the read buffer in the code
        },
        -- 30k option
        -- placed here even though it's not an extension, because
        --  if placed elsewhere, would break other options
        --NOTE actually, this would break trying to use debug extension and 30k option at the same time
        --["30k"] = {
        --    [">"] = "if c>30000 then c=0 end",
        --    ["<"] = "if c<0 then c=30000 end"
        --}
    }
}

--[[ debug extension # command
    for i=0,9 do
        w('m['..c..']='..m[c]..',')
    end
    w('\\n')
    for i=c-4,c+4 do
        w('m['..i..']='..m[i]..',')
    end
--]]

-- compile options, including extensions enabled
local options = {
    IN_FILE = "",    -- set later
    OUT_FILE = "",   -- set later
    TO_FILE = false, -- will be set true if called, stays false if required

    BOOTSTRAP = {
        core = "default",
        input = "default",
        post = "default"
    },
    INSTRUCTION_SET = {
        core = "default",
        post = "default",
        --fallback = "default" -- the idea here is to have a fallback defined that is a complete set of instructions
    },
    EXTENSIONS = {},
    FLAGS ={}, -- used for extension handling

    VERBOSE = false,
    DEBUG = false,
    ["30K"] = false
}

-- extra processing required to use extensions
local extensions = {
    debug = {
        instruction = function(handle, character)
            if options.FLAGS.debug then
                if character == "\\" then
                    handle:write("\\\\")
                elseif character == "'" then
                    handle:write("\\'")
                --TODO fix the fact that we don't properly
                -- handle newlines (they are handled by the
                -- for loop we are in!!)
                --elseif character == "\n" then
                --    handle:write("\\n")
                else
                    handle:write(character)
                end
                return true
            else
                if character == "!" then
                    options.FLAGS.debug = true
                end
            end
            return false
        end,

        post = function(handle)
            if options.FLAGS.debug then
                handle:write("' M()") -- end read buffer, run everything
                return true
            else
                handle:write(" end M()") -- read buffer was never started, end function and run it
                return true
            end
        end
    }
}
--TODO give extensions metatable that will print error if attempting to use non-existent extension

-- argument handling
local arguments = {...}

-- check if an argument option was selected
local function selected(option)
    for k,v in ipairs(arguments) do
        if v == option then
            return true, k
        elseif v == "--" then
            return false
        end
    end
    return false
end

-- check for the more advanced options being selected
local function fuzzySelected(option)
    for k,v in ipairs(arguments) do
        if v:find(option) == 1 then
            return true, k
        elseif v == "--" then
            return false
        end
    end
    return false
end

-- used in verbose output to show options
local function printTable(Table, currentDepth)
    if not currentDepth then currentDepth = 0 end
    local SPACER = ("  "):rep(currentDepth)

    print(SPACER .. "{")

    for k,v in pairs(Table) do
        if type(v) == "table" then
            print(" " .. SPACER .. k .. " =")
            printTable(v, currentDepth + 1)
        elseif type(v) == "string" then
            print(" " .. SPACER .. k .. " = \"" .. v .. "\"")
        else
            print(" " .. SPACER .. k .. " = " .. tostring(v))
        end
    end

    print(SPACER .. "}")
end

-- used in grabbing extensions, only splits based on commas
local function split(str)
    local words = {}

    for word in string.gmatch(str, '([^,]+)') do
        print(word)
        table.insert(words, word)
    end

    return words
end

--TODO check for option strings (like -sdw or whatever) by doing a search for an
-- arg that starts with a - and has more than 2 characters length, then parse
-- any matches to the arguments as "-X" where X is the characters, do this first
-- and process the rest as normal (note to self, must INSERT these additions to
-- properly preserve order of arguments (INPUT [OPTIONS] [filename]))

local function LuaFuck(...)
    --NOTE TODO if silent option, locally replace print with nil function
    arguments = {...}

    -- initial options & easy outs
    if (#arguments == 0) or selected("-h") or selected("--help") then
        print(help)
        return
    elseif selected("-v") or selected("--version") then
        print("LuaFuck " .. tostring(version))
        return
    else
        options.IN_FILE = arguments[1]
        options.OUT_FILE = arguments[1]:sub(1, -4)
    end

    -- easy options
    if selected("-V") or selected("--verbose") then
        options.VERBOSE = true
    end
    if selected("-d") or selected("--debug") then
        options.DEBUG = true
        options.BOOTSTRAP.core = "debug"
        options.INSTRUCTION_SET.core = "debug"
        options.INSTRUCTION_SET.post = "debug"
    end
    if selected("-3") or selected("--30k") then
        options["30K"] = true
        --TODO actually implement this
    end

    -- difficult options
    local yes, arg = selected("-o")
    if yes then
        options.OUT_FILE = arguments[arg+1]
    else
        yes, arg = fuzzySelected("--out=")
        if yes then
            options.OUT_FILE = arguments[arg]:sub(7)
        end
    end
    -- extension option
    yes, arg = selected("-e")
    if yes then
        --TODO we need a way make sure every argument we grab past arguments[arg]
        --      is NOT another argument (and thus, is an extension to grab)
        --IDEA commands {} holding "-v", "-h", etc, check against these before parsing it
        --      and then fuzzyCommands {} holding "--out=", "--extensions=" etc
        -- if arg does not match one of commands{} or beginning of fuzzyCommands{},
        --  it is an extension
    else
        yes, arg = fuzzySelected("--extensions=")
        if yes then
            options.EXTENSIONS = split(arguments[arg]:sub(13))
        end
    end

    -- handle any changes to options based on chosen extensions
    for _,v in ipairs(options.EXTENSIONS) do
        if v == "debug" then
            options.BOOTSTRAP.input = "debug"
            options.INSTRUCTION_SET.extend = "debug"
        end
    end

    -- make sure options.OUT_FILE ends with a ".lua"
    if not options.OUT_FILE:find(".lua") then
        options.OUT_FILE = options.OUT_FILE .. ".lua"
    end

    -- do some verbose shit, man
    if options.VERBOSE then
        print("Verbose mode activated!")
        print("Parsed options:")

        printTable(options)
    end

    -- check that our input file exists
    local file = io.open(options.IN_FILE, "r")
    if file ~= nil then
        file:close() -- everything is awesome
    else
        print("ERROR: Source file \"" .. options.IN_FILE .. "\" does not exist!")
        return
    end

    -- set up what we will return / how we will write out data
    --  required     -> return compiled string
    --  command-line -> return "" (and write to file)
    local OUTPUT = ""
    local outHandle = {}
    if options.TO_FILE then
        if options.VERBOSE then
            print("Opening \"" .. options.OUT_FILE .. "\" for output...")
        end
        outHandle = io.open(options.OUT_FILE, "w")
    else
        -- we fake it for the required version
        outHandle.write = function(self, data)
            OUTPUT = OUTPUT .. data
        end
        outHandle.close = function(self)
        end
    end

    -- write bootstrap code
    if options.VERBOSE then
        print("Writing bootstrap code...")
    end
    -- these are the ONLY two writes that should not have a prepended space
    outHandle:write(bootstrap.core[options.BOOTSTRAP.core])
    outHandle:write(" " .. bootstrap.input[options.BOOTSTRAP.input])
    outHandle:write(" " .. bootstrap.post[options.BOOTSTRAP.post])
    if options.VERBOSE then
        print("Done.")
    end

    -- write out instructions
    --NOTE TODO add checking for mathcing [] by counting number of each
    -- encountered and warning on mismatch (erroring actually)
    local CORE = instructions.core[options.INSTRUCTION_SET.core]
    local POST = instructions.post[options.INSTRUCTION_SET.post]
    local EXTEND = instructions.extend[options.INSTRUCTION_SET.extend]

    for line in io.lines(options.IN_FILE) do
        if options.VERBOSE then
            print("Processing line: \"" .. line .. "\"")
        end

        --TODO place pseudo-call for a newline here!!

        for i=1, line:len() do
            local character = line:sub(i, i)

            -- extension handling
            local handled = false
            for _,v in ipairs(options.EXTENSIONS) do
                handled = extensions[v].instruction(outHandle, character)
                if handled then
                    -- I think this is appropriate, the first extension to
                    --  handle something handles it, we're done
                    break
                end
            end

            -- normal instruction mapping
            if not handled then
                if CORE and CORE[character] then
                    outHandle:write(" " .. CORE[character])
                    if options.VERBOSE then
                        print("(core)    Wrote: \"" .. character .. "\" as \"" .. CORE[character] .. "\"")
                    end
                end
                if POST and POST[character] then
                    outHandle:write(" " .. POST[character])
                    if options.VERBOSE then
                        print("(post)    Wrote: \"" .. character .. "\" as \"" .. POST[character] .. "\"")
                    end
                end
                if EXTEND and EXTEND[character] then
                    outHandle:write(" " .. EXTEND[character])
                    if options.VERBOSE then
                        print("(extra)   Wrote: \"" .. character .. "\" as \"" .. EXTEND[character] .. "\"")
                    end
                end
            end
        end
    end

    -- extension handling
    for _,v in ipairs(options.EXTENSIONS) do
        if extensions[v].post(outHandle) then
            break
        end
    end

    outHandle:close()
    print("Compilation complete: \"" .. options.OUT_FILE .. "\"")

    return OUTPUT
end

-- this file can be called directly OR required
if arguments[1] ~= "luafuck" then
    options.TO_FILE = true
    return LuaFuck(...)
else
    return LuaFuck
end
