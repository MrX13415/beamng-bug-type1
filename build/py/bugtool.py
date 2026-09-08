import os
import sys
import session
from util import *
import buildaw
import publish

shellRunning = False

def init():
    return session.init()
#end

def printHeader():
    print("BugTool v1.1")
    print("Root: " + session.root)
#end

def printUsage(error=True, command=None):
    if command is not None:  
        print(f"Unknown command '{command}'.")
        print("")
    #end

    if not shellRunning:
        print("Usage: bugtool <commands>")
    else:
        print("Available Commands:")
    
    print("")
    print("  aw              Tools to create the AW branded variant.")
    print("  publish         Compress the mod for publishing.")
    print("  githash         Shows the current git commit hash.")
    print("  gitbranch       Shows the current git branch.")
    print("  modinfo         Shows the version information of the mod.")
    print("  help            This message.")
    if not shellRunning:
        print("  shell           Starts the interactive shell.")
    else:
        print("  exit            Exit.")
    
    print("")

    return 2 if error else 0
#end

def printGitHash():
    hash = gitCommitHash()
    if shellRunning:
        hashStr = ("n/a" if hash is None else hash)
        print(f"Current Commit: {hashStr}")
    else:
        print(hash)
    return 0 if hash is not None else 1
#end

def printGitBranch():
    branch = gitBranch()
    if shellRunning:
        branchStr = ("n/a" if branch is None else branch)
        print(f"Current Branch: {branchStr}")
    else:
        print(branch)
    return 0 if branch is not None else 1
#end

def printModInfo():
    info = publish.getModInfo()
    print(info.toString())
    print("")
    return 0
#end

def runShell():
    global shellRunning

    if not init(): return 1

    if shellRunning:
        print("Shell is already running...")
        return 0
    
    printHeader()

    while True:
        shellRunning = True

        rawInput = input("> ")
        commands = getCommands(rawInput)
        if len(commands) == 0: continue

        if isCommand(commands[0], "exit", "quit", "x"): 
            break;
        #end

        processCommand(commands)
    #end

    shellRunning = False
    print("Exit...")
    return 0
#end

def processCommand(commands):
    cmd = popCommand(commands)
    ok = True

    if isCommand(cmd, "aw"):
        return buildaw.main(fullCommands(commands), False)
    elif isCommand(cmd, "publish", "zip"):
        return publish.main(fullCommands(commands), False)
    elif isCommand(cmd, "githash"):
        return printGitHash()
    elif isCommand(cmd, "gitbranch"):
        return printGitBranch()
    elif isCommand(cmd, "modinfo", "modver", "modversion", "bugver", "bugversion"):
        return printModInfo()
    elif isCommand(cmd, "shell", "ui"):        
        return runShell()
    elif isCommand(cmd, "help") or isCommandHelp(cmd):
        return printUsage(False)

    return printUsage(True, cmd)
#end

def main(args=None):
    if not init(): return 1

    if args is None: args = sys.argv
    if len(args) < 2: return printUsage()

    return processCommand(args[1:])
#end

if __name__ == '__main__':
    sys.exit(main())