{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE CPP                 #-}
module Devel
    ( devel
    ) where

import Filesystem.Path.CurrentOS (encodeString, decodeString)

import qualified Distribution.Simple.Utils as D
import qualified Distribution.Verbosity as D
import qualified Distribution.PackageDescription.Parse as D
import qualified Distribution.PackageDescription as D
import qualified Distribution.ModuleName as D

import           Control.Concurrent (forkIO, threadDelay)
import           Control.Concurrent.Chan (Chan, newChan, readChan)
import qualified Control.Exception as Ex
import           Control.Monad (forever, when, unless)

import           Data.Char (isUpper, isNumber)
import qualified Data.List as L
import qualified Data.Map as Map
import qualified Data.Set as Set
import           Data.Time ()
import           Data.Time.Clock (UTCTime, getCurrentTime)

import           System.Directory
import           System.Exit (exitFailure, exitSuccess, ExitCode (..))
import           System.FilePath (splitDirectories, dropExtension, takeExtension)
import           System.Posix.Types (EpochTime)
import           System.PosixCompat.Files (modificationTime, getFileStatus)
import           System.Process (createProcess, proc, terminateProcess, readProcess,
                                           waitForProcess, rawSystem, runInteractiveProcess)
import           System.IO (hClose, hIsEOF, hGetLine, stdout, stderr, hPutStrLn)
import           System.IO.FSNotify

import Build (recompDeps, getDeps)

lockFile :: FilePath
lockFile = "dist/devel-terminate"

writeLock :: IO ()
writeLock = do
    createDirectoryIfMissing True "dist"
    writeFile lockFile ""

removeLock :: IO ()
removeLock = try_ (removeFile lockFile)

devel :: Bool -> [String] -> IO ()
devel isCabalDev passThroughArgs = do
    checkDevelFile
    writeLock

    putStrLn "Yesod devel server. Press ENTER to quit"
    _ <- forkIO $ do
      cabal <- D.findPackageDesc "."
      gpd   <- D.readPackageDescription D.normal cabal

      hsSourceDirs <- checkCabalFile gpd

      _<- rawSystem cmd args

      mainLoop hsSourceDirs

    _ <- getLine
    writeLock
    exitSuccess
  where
    cmd | isCabalDev = "cabal-dev"
        | otherwise  = "cabal"

    diffArgs | isCabalDev = [
              "--cabal-install-arg=-fdevel" -- legacy
            , "--cabal-install-arg=-flibrary-only"
            ]
             | otherwise  = [
              "-fdevel" -- legacy
            , "-flibrary-only"
            ]
    args = "configure":diffArgs ++ ["--disable-library-profiling" ]

    mainLoop :: [FilePath] -> IO ()
    mainLoop hsSourceDirs = do
       ghcVer <- ghcVersion
       when isCabalDev (rawSystemFilter cmd ["build"] >> return ())  -- cabal-dev fails with strange errors sometimes if we cabal-dev buildinfo before cabal-dev build
       pkgArgs <- ghcPackageArgs isCabalDev ghcVer
       let devArgs = pkgArgs ++ ["devel.hs"] ++ passThroughArgs

       eventChan <- newChan
       watchManager <- startManager
       _ <- mapM_ (\path -> watchTreeChan watchManager (decodeString path) (\_ -> True) eventChan) hsSourceDirs

       forever $ do
           putStrLn "Rebuilding application..."

           buildStartTime <- getCurrentTime
           recompDeps hsSourceDirs
           exit <- rawSystemFilter cmd ["build"]

           case exit of
             ExitFailure _ -> putStrLn "Build failure, pausing..."
             _ -> do
                   removeLock
                   putStrLn $ "Starting development server: runghc " ++ L.unwords devArgs
                   (_,_,_,ph) <- createProcess $ proc "runghc" devArgs
                   watchTid <- forkIO . try_ $ do
                         waitForChanges buildStartTime eventChan
                         putStrLn "Stopping development server..."
                         writeLock
                         threadDelay 1000000
                         putStrLn "Terminating development server..."
                         terminateProcess ph
                   ec <- waitForProcess ph
                   putStrLn $ "Exit code: " ++ show ec
                   Ex.throwTo watchTid (userError "process finished")
           waitForChanges buildStartTime eventChan

try_ :: forall a. IO a -> IO ()
try_ x = (Ex.try x :: IO (Either Ex.SomeException a)) >> return ()

type FileList = Map.Map FilePath EpochTime

getFileList :: [FilePath] -> IO FileList
getFileList hsSourceDirs = do
    (files, deps) <- getDeps hsSourceDirs
    let files' = files ++ map fst (Map.toList deps)
    fmap Map.fromList $ flip mapM files' $ \f -> do
        efs <- Ex.try $ getFileStatus f
        return $ case efs of
            Left (_ :: Ex.SomeException) -> (f, 0)
            Right fs -> (f, modificationTime fs)

waitForChanges :: UTCTime -> Chan Event -> IO ()
waitForChanges buildStartTime eventChan = do
    evtTime <- return . eventTime =<< readChan eventChan
    if evtTime >= buildStartTime
      then return ()
      else waitForChanges buildStartTime eventChan

checkDevelFile :: IO ()
checkDevelFile = do
  e <- doesFileExist "devel.hs"
  unless e $ failWith "file devel.hs not found"

checkCabalFile :: D.GenericPackageDescription -> IO [FilePath]
checkCabalFile gpd = case D.condLibrary gpd of
    Nothing -> failWith "incorrect cabal file, no library"
    Just ct ->
      case lookupDevelLib gpd ct of
        Nothing   ->
          failWith "no development flag found in your configuration file. Expected a 'library-only' flag or the older 'devel' flag"
        Just dLib -> do
           let hsSourceDirs = D.hsSourceDirs . D.libBuildInfo $ dLib
           fl <- getFileList hsSourceDirs
           let unlisted = checkFileList fl dLib
           unless (null unlisted) $ do
                putStrLn "WARNING: the following source files are not listed in exposed-modules or other-modules:"
                mapM_ putStrLn unlisted
           when (D.fromString "Application" `notElem` D.exposedModules dLib) $
                putStrLn "WARNING: no exposed module Application"
           return hsSourceDirs

failWith :: String -> IO a
failWith msg = do
    putStrLn $ "ERROR: " ++ msg
    exitFailure

checkFileList :: FileList -> D.Library -> [FilePath]
checkFileList fl lib = filter isUnlisted . filter isSrcFile $ sourceFiles
  where
    al = allModules lib
    -- a file is only a possible 'module file' if all path pieces start with a capital letter
    sourceFiles = filter isSrcFile . map fst . Map.toList $ fl
    isSrcFile file = let dirs = filter (/=".") $ splitDirectories file
                     in  all (isUpper . head) dirs && (takeExtension file `elem` [".hs", ".lhs"])
    isUnlisted file = not (toModuleName file `Set.member` al)
    toModuleName = L.intercalate "." . filter (/=".") . splitDirectories . dropExtension

allModules :: D.Library -> Set.Set String
allModules lib = Set.fromList $ map toString $ D.exposedModules lib ++ (D.otherModules . D.libBuildInfo) lib
    where
      toString = L.intercalate "." . D.components

ghcVersion :: IO String
ghcVersion = fmap getNumber $ readProcess "runghc" ["--numeric-version", "0"] []
    where
      getNumber = filter (\x -> isNumber x || x == '.')

ghcPackageArgs :: Bool -> String -> IO [String]
ghcPackageArgs isCabalDev ghcVer
  | isCabalDev = do
      r <- readProcess "cabal-dev" ["buildopts"] []
      let opts = L.lines r
      return $ "-hide-all-packages" : "-no-user-package-conf" : inplacePkg : cabaldevConf : pkgid opts : depPkgIds opts
  | otherwise = return [inplacePkg]
      where
        pkgid opts      = let (_,p) = head (selectOpts ["-package-name"] opts) in "-package-id" ++ p ++ "-inplace"
        depPkgIds opts  = map (uncurry (++)) (selectOpts ["-package-id"] opts)
        inplacePkg   = "-package-confdist/package.conf.inplace"
        cabaldevConf = "-package-confcabal-dev/packages-" ++ ghcVer ++ ".conf"
        selectOpts opts (x1:x2:xs)
           | x1 `elem` opts = (x1,x2):selectOpts opts xs
           | otherwise      = selectOpts opts (x2:xs)
        selectOpts _ _ = []

lookupDevelLib :: D.GenericPackageDescription -> D.CondTree D.ConfVar c a -> Maybe a
lookupDevelLib gpd ct | found     = Just (D.condTreeData ct)
                      | otherwise = Nothing
  where
    flags = map (unFlagName . D.flagName) $ D.genPackageFlags gpd
    unFlagName (D.FlagName x) = x
    found = any (`elem` ["library-only", "devel"]) flags

-- | Acts like @rawSystem@, but filters out lines from the output that we're not interested in seeing.
rawSystemFilter :: String -> [String] -> IO ExitCode
rawSystemFilter command args = do
    (inh, outh, errh, ph) <- runInteractiveProcess command args Nothing Nothing
    hClose inh
    let go handlein handleout = do
            isEof <- hIsEOF handlein
            if isEof
                then hClose handlein
                else do
                    line <- hGetLine handlein
                    unless ("Loading package " `L.isPrefixOf` line) $ hPutStrLn handleout line
                    go handlein handleout
    _ <- forkIO $ go outh stdout
    _ <- forkIO $ go errh stderr
    waitForProcess ph
