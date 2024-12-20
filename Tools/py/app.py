import os
import session
from util import *
import makeaw

def init():
    return session.init()
#end

def printHeader():
    print("BugTool v1.0")
    print("Root: " + session.root)
#end

def printHelp():
    print("")
    print("Available Commands:")
    print("")
    print("  makeaw          Tools to create the repo version.")
    print("  help            This message.")
    print("  exit            Exit.")
    print("")
#end

def processCommand(commands):
    cmd = popCommand(commands)
    ok = True

    if match(cmd, "makeaw"):
        makeaw.processCommand(commands)
    elif match(cmd, "test"):
        print("Test!")
    elif match(cmd, "help", "h", "?"):
        printHelp()
    else:
        ok = False
        print(f"Unknown command '{cmd}'.")       
        printHelp()
    #end 

    return ok
#end

def main():
    os.system('color')

    if not init(): return
    printHeader()
    
    while True:
        rawInput = input("> ")
        commands = getCommands(rawInput)
        if len(commands) == 0: continue

        if match(commands[0], "exit", "quit", "x"): 
            break;
        #end

        processCommand(commands)
    #end

    print("Exit...")
#end

if __name__ == '__main__':
    main()