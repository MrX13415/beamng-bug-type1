import os

def dirname(path, index=0):
    for i in range(index+1):
        path = os.path.dirname(path)
    return path
#end

def fileCount(folder):
    count = 0
    for root, dirs, files in os.walk(folder):
        count += len(files)
    #end
    return count
#end

def match(var, *matches):
    for c in matches:
        if var == c: return True
    #end
    return False
#end

def asCommand(rawInput):
    return rawInput.lower().strip()
#end
def getCommands(rawInput):
    entires = rawInput.split()
    return [asCommand(e) for e in entires]
#end
def popCommand(commands, index=0):
    return commands.pop(index) if len(commands) > 0 else ""
#end