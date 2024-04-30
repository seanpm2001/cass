--------------------------------------------------------------------------
--- This is the main module to start the executable of the analysis system.
---
--- @author Michael Hanus
--- @version April 2024
--------------------------------------------------------------------------

module CASS.Main ( main ) where

import Data.Char             ( toLower )
import Data.List             ( isPrefixOf, isSuffixOf, sort, init )
import Control.Monad         ( when, unless )
import System.CurryPath      ( stripCurrySuffix )
import System.FilePath       ( (</>), (<.>) )
import System.Process        ( exitWith )
import System.Environment    ( getArgs )
import System.Console.GetOpt

import Analysis.Files     ( deleteAllAnalysisFiles )
import Analysis.Logging   ( debugMessage )
import CASS.Configuration
import CASS.Doc           ( getAnalysisDoc )
import CASS.Options
import CASS.Server        ( analyzeModuleAndPrint, mainServer )
import CASS.Registry      ( registeredAnalysisInfos, registeredAnalysisNames )
import CASS.Worker        ( startWorker )

--- Main function to start the analysis system.
--- With option -s or --server, the server is started on a socket.
--- Otherwise, it is started in batch mode to analyze a single module.
main :: IO ()
main = do
  argv <- getArgs
  let (funopts, args, opterrors) = getOpt Permute options argv
  let opts = foldl (flip id) defaultOptions funopts
  unless (null opterrors)
         (putStr (unlines opterrors) >> putStr usageText >> exitWith 1)
  cconfig <- readRCFile
  when (optHelp opts) (printHelp args >> exitWith 1)
  when (optDelete opts) (deleteFiles args)
  when ((optServer opts && not (null args)) ||
        (not (optServer opts) && length args /= 2))
       (writeErrorAndExit "Illegal arguments (try `-h' for help)")
  when (optWorker opts && length args /= 2)
       (writeErrorAndExit "Illegal arguments (try `-h' for help)")
  let cconfig1 = foldr (uncurry updateProperty) cconfig (optProp opts)
      verb     = optVerb opts
      cconfig2 = if verb >= 0
                   then setDebugLevel verb cconfig1
                   else cconfig1
      dl       = debugLevel cconfig2
  debugMessage dl 1 systemBanner
  if optServer opts
   then mainServer cconfig2
                   (let p = optPort opts in if p == 0 then Nothing else Just p)
   else
     if optWorker opts
       then startWorker cconfig2 (head args) (read (args!!1))
       else do
         let [ananame,mname] = args
         fullananame <- checkAnalysisName ananame
         debugMessage dl 1 $
           "Computing results for analysis `" ++ fullananame ++ "'"
         analyzeModuleAndPrint cconfig2 fullananame (stripCurrySuffix mname)
                               (optAll opts) (optFormat opts) (optReAna opts)
 where
  deleteFiles args = case args of
    [aname] -> do fullaname <- checkAnalysisName aname
                  putStrLn $ "Deleting files for analysis `" ++ fullaname ++ "'"
                  deleteAllAnalysisFiles fullaname
                  exitWith 0
    [] -> writeErrorAndExit "Missing analysis name!"
    _  -> writeErrorAndExit
            "Too many arguments (only analysis name should be given)!"

writeErrorAndExit :: String -> IO _
writeErrorAndExit msg = putStrLn ("ERROR: " ++ msg) >> exitWith 1

-- Checks whether a given analysis name is a unique abbreviation
-- of a registered analysis name and return the registered name.
-- Otherwise, raise an error.
checkAnalysisName :: String -> IO String
checkAnalysisName aname = case matchedNames of
  []       -> writeErrorAndExit $
                "Unknown analysis name `"++ aname ++ "' " ++ tryCmt
  [raname] -> return raname
  (_:_:_)  -> writeErrorAndExit $
                "Analysis name `"++ aname ++ "' not unique " ++ tryCmt ++
                ":\nPossible names are: " ++ unwords matchedNames
 where
  laname        = map toLower aname
  exactMatches  = filter ((== laname) . map toLower)
                         registeredAnalysisNames
  prefixMatches = filter (isPrefixOf laname . map toLower)
                         registeredAnalysisNames
  matchedNames  = if null exactMatches then prefixMatches else exactMatches
  tryCmt        = "(try `-h' for help)"

--------------------------------------------------------------------------
-- Printing help:
printHelp :: [String] -> IO ()
printHelp args =
  if null args
   then putStrLn $ systemBanner ++ "\n" ++ usageText
   else do aname <- checkAnalysisName (head args)
           getAnalysisDoc aname >>=
             maybe (putStrLn $
                      "Sorry, no documentation for analysis `" ++ aname ++ "'")
                   putStrLn

-- Help text
usageText :: String
usageText =
  usageInfo ("Usage: cass <options> <analysis name> <module name>\n" ++
             "   or: cass <options> [-s|--server]\n" ++
             "   or: cass [-w|--worker] <host> <port>\n")
            options ++
  unlines ("" : "Registered analyses names:" :
           "(use option `-h <analysis name>' for more documentation)" :
           "" : map showAnaInfo (sort registeredAnalysisInfos))
 where
  maxName = foldr1 max (map (length . fst) registeredAnalysisInfos) + 1
  showAnaInfo (n,t) = n ++ take (maxName - length n) (repeat ' ') ++ ": " ++ t

--------------------------------------------------------------------------
