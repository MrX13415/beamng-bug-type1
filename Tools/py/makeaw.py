import os
import sys
import glob
import shutil
import session
from util import *

SourceFolder = "bug"
TargetFolder = "bug-aw"
ModFolder = "#mod"

targetFiles = [ "txt", "json", "jbeam", "lua"]
codeFiles = [ "lua" ]
WordMap = {
    # Movie names: Just remove them entirely for now.
    '\"The Love Bug\" '                 : '',
    '\"Herbie Goes to Monte Carlo\" '   : '',
    '\"Herbie Goes Bananas\" '          : '',
    '\"Herbie: Fully Loaded\" '         : '',

    # Special strings
    'Volkswagen Type 1 \"Beetle\"'      : 'AW Type 1',      # Explicitly set the name.
    'Volkswagen Lettering'              : 'AW Lettering',   # The letterings just reads "AW" instead of the full name.
    
    # General strings
    'vw'        : 'aw',
    'Vw'        : 'Aw',
    'VW'        : 'AW',
    'volkswagen': 'aw', # 'autowolf',
    'Volkswagen': 'AW', # 'Automobilwerke Wolfsburg',
    'VOLKSWAGEN': 'AW', # 'AUTOMOBILWERKE WOLFSBURG',
    'käfer'     : 'bug',
    'Käfer'     : 'Bug',
    'KÄFER'     : 'BUG',
    'beetle'    : 'bug',
    'Beetle'    : 'Bug',
    'BEETLE'    : 'BUG',
    'herbie'    : 'curby', #'herbert', 
    'Herbie'    : 'Curby', #'Herbert', 
    'HERBIE'    : 'CURBY', #'HERBERT', 
    'carello'   : 'carelu',
    'Carello'   : 'Carelu',
    'CARELLO'   : 'CARELU',
}
IgnoreWords = [ '53_herbie_53' ]



def getFiles(path):
    return glob.glob(os.path.join(path, "**/*"), recursive=True)
#end

def getFilesByExt(path, extList):
    result = []
    for f in getFiles(path):
        if not os.path.isfile(f): continue
        ext = os.path.splitext(f)[1][1:] # also remove dot (.)
        for e in extList:
            if e.lower() == ext.lower(): result.append(f)
        #end
    #end
    return result
#end

def getRemovableFiles(path):
    # Determine files to be removed
    return [f for f in getFiles(path) if not os.path.relpath(f, path).startswith(ModFolder)]
#end
def copyFiles(source, target):
    shutil.copytree(source, target, dirs_exist_ok = True)
#end

def applyWordMap(line):

    # Check if line contains any of the words to be replaced
    for k, v in WordMap.items():
        if not k in line: continue

        ignoreMap = {}
        ignoreIndex = 0
        for ignore in IgnoreWords:
            if not ignore in line: continue

            ignoreKey = f"⌈{ignoreIndex}⌉"  # Use a unique key for each ignore word
            ignoreMap[ignoreKey] = ignore
            ignoreIndex += 1

            line = line.replace(ignore, ignoreKey)
        #end

        line = line.replace(k, v)

        # Revert ignored words back to their original form
        for ignoreKey, ignore in ignoreMap.items():
            line = line.replace(ignoreKey, ignore)
        #end
    #end

    return line
#end

def findStringLiteral(line, startIndex=0):
    startPos = -1
    length = 0
    quoteChar = ''
    inString = False
    isEscaped = False

    for index in range(startIndex, len(line)):
        char = line[index]
        
        # Handle escaped characters
        if char == '\\' or isEscaped: 
            isEscaped = not isEscaped
            continue
        #end

        isQuote = char in ('"', "'")
        if isQuote and not inString:
            inString = True
            quoteChar = char
            startPos = index
            continue
        #end

        if not inString: continue
        if char == quoteChar and not isEscaped:
            length = index - startPos + 1
            break
        #end
    #end

    if not inString or length == 0:
        return (-1, 0, "")

    stringLiteral = line[startPos:startPos + length]
    return (startPos, length, stringLiteral)
#end

def processCode(line):
    startIndex = 0

    while True:
        pos, length, stringLiteral = findStringLiteral(line, startIndex)

        # No more string literals found
        if pos == -1 or length == 0: break

        # Relace words in string literals and update the line
        stringLiteral = applyWordMap(stringLiteral)
        line = line[:pos] + stringLiteral + line[pos + length:]

        # Update startIndex to continue searching after the current string literal
        startIndex = pos + len(stringLiteral)  
    #end

    return line
#end

def updateTextFile(file, wordmap):
    with open(file, 'r', encoding='utf-8') as f:
        content = f.read()
    #end

    isCode = os.path.splitext(file)[1][1:] in codeFiles

    content = content.replace("\r\n", "\n")  # Normalize line endings to LF
    content = content.replace("\r", "\n")     # Normalize line endings to LF

    lines = content.splitlines()
    changes = []

    for i in range(len(lines)):
        line = lines[i]
        if len(line) == 0: continue

        if isCode:
            line = processCode(line)
        else:
            line = applyWordMap(line)
        #end

        if line == lines[i]: continue

        # Line has changed, update it
        changes.append((lines[i], line)) 
        lines[i] = line
    #end

    if len(changes) == 0: return []

    content = "\n".join(lines) + "\n"  # Ensure the file ends with a newline

    with open(file, 'w', encoding='utf-8') as f:
        f.write(content)

    return changes
#end

def updateTextFiles(target, wordmap):
    for f in getFilesByExt(target, targetFiles):
        changes = updateTextFile(f, wordmap)
        if len(changes) == 0: continue

        print(f"   Update '{os.path.relpath(f, root)}'")

        for k,v in changes:
            print(f"     -> {k.strip()}\n        {v.strip()}\n")
        #end
    #end
#end


__init = False
root = ""
source = ""
target = ""
mod = ""


def init():
    global __init
    global root
    global source
    global target
    global mod

    if __init: return True

    source = ""
    target = ""
    mod = ""

    root = session.root #   dirname(os.path.realpath(__file__), 2)       # Get the second parent folder
    
    #debug: root = os.path.join(root, "x")

    # Root path correct?
    if not os.path.exists(os.path.join(root, SourceFolder)):
        print("Error: Root path does not contain expected folders.")
        return False
    #end

    source = os.path.join(root, SourceFolder)
    target = os.path.join(root, TargetFolder)
    mod = os.path.join(target, ModFolder)

    __init = True
    return True
#end

def printUsage():
    print("Usage: aw <command>")
    print("")
    print("  build           Builds the AW branded variant in 'bug-aw'.")

    print("  clean           Only runs the clean step.")
    print("  copy            Only runs the copy step.")
    print("  apply           Only runs the apply step.")
    print("")
#end

def printPaths():
    print(" Source: " + os.path.relpath(source, root))
    print(" Target: " + os.path.relpath(target, root))
    print("    Mod: " + os.path.relpath(mod, root))
#end

def clean():
    if not init(): return

    print("- Clean folder ...")

    # Determine files to be removed
    files = getRemovableFiles(target)

    for f in files:
        if not os.path.isfile(f): continue
        print(f"   Remove '{os.path.relpath(f, root)}'")
        os.remove(f)
    #end

    for d in files:
        if not os.path.isdir(d): continue
        shutil.rmtree(d)
    #end

    print("  OK")
#end

def copy():
    if not init(): return

    print("- Copy files ...")
    
    # copy files
    copyFiles(source, target)

    print("  OK")
#end

def apply():
    if not init(): return

    print("- Apply mod files ...")

    # overwrite vw with aw files
    copyFiles(mod, target)

    updateTextFiles(target, WordMap)

    print("  OK")
#end

def build():
    if not init(): return

    printPaths()
    
    clean()
    copy()
    apply()
#end

def processCommand(commands):
    cmd = popCommand(commands)

    if cmd == "clean": clean()
    elif cmd == "copy": copy()
    elif cmd == "apply": apply()
    elif cmd == "build": build()
    else: 
        printUsage()
        return
    #end
#end

def main():
    if not init(): return
    
    if len(sys.argv) != 2:
        printUsage()
        return
    #end

    print("   Root: " + root)
    processCommand([asCommand(sys.argv[1])])
#end

if __name__ == '__main__':
    main()