{-|
  Copyright   : (c) 2015 Javran Cheng
  License     : MIT
  Maintainer  : Javran.C@gmail.com
  Stability   : unstable
  Portability : non-portable (requires X11)

  Compiling-related functions

-}
module XMonad.Util.EntryHelper.Compile
  ( defaultCompile
  , defaultPostCompile
  , postCompileCheckLog
  , compileUsingShell
  , withFileLock
  , withLock
  ) where

import Data.Functor
import Control.Applicative
import Control.Monad
import System.IO
import System.Posix.Process
import System.Process
import Control.Exception.Extensible
import System.Exit
import System.FilePath
import System.Directory
import Data.List
import System.Posix.User

import XMonad.Util.EntryHelper.File
import XMonad.Util.EntryHelper.Util

-- | the default compiling action.
--   checks whether any of the sources files under @"~\/.xmonad\/"@
--   is newer than the binary and recompiles XMonad if so.
defaultCompile :: Bool -> IO ExitCode
defaultCompile force = do
    b <- isSourceNewer
    if force || b
      then do
        bin <- binPath <$> getXMonadPaths
        let cmd = "ghc --make xmonad.hs -i -ilib -fforce-recomp -o " ++ bin
        compileUsingShell cmd
      else return ExitSuccess

-- | the default post-compiling action.
--   same as @postCompileCheckLog errlog@
--   where @errlog@ is the default error log location
--   (usually @"~\/.xmonad\/xmonad.errors"@)
--   see also: 'postCompileCheckLog'
defaultPostCompile :: ExitCode -> IO ()
defaultPostCompile e = join (postCompileCheckLog <$> getXMonadLog
                                                 <*> pure e)
-- | a post-compiling action.
--   @postCompileCheckLog fp ec@
--   first checks the 'ExitCode' given, if it is not equal to 'ExitSuccess',
--   prints out error log to stderr and pops up a message
--   containing the error log.
--   the error log is indicated by @fpath@
postCompileCheckLog :: FilePath -> ExitCode -> IO ()
postCompileCheckLog _ ExitSuccess = return ()
postCompileCheckLog fpath st@(ExitFailure _) = do
    ghcErr <- readFile fpath
    let msg = unlines $
              [ "Error detected while loading xmonad configuration file(s)" ]
              ++ lines (if null ghcErr then show st else ghcErr)
              ++ ["","Please check the file for errors."]
    hPutStrLn stderr msg
    void $ forkProcess $ executeFile "xmessage" True ["-default", "okay", msg] Nothing

-- | @compileUsingShell cmd@ spawns a new process to run a shell command
--   (shell expansion is applied).
--   The working directory of the shell command is @"~\/.xmonad\/"@, and
--   the process' stdout and stdout are redirected to @"~\/.xmonad\/xmonad.errors"@
compileUsingShell :: String -> IO ExitCode
compileUsingShell cmd = do
    -- please make sure "installSignalHandlers" hasn't been executed
    -- or has been undone by "uninstallSignalHandlers"
    -- see also: https://ghc.haskell.org/trac/ghc/ticket/5212
    dir <- getXMonadDir
    compileLogPath <- getXMonadLog
    hNullInput <- openFile "/dev/null" ReadMode
    hCompileLog <- openFile compileLogPath WriteMode
    hSetBuffering hCompileLog NoBuffering
    let cp = (shell cmd)
               { cwd     = Just dir
               , std_in  = UseHandle hNullInput
               , std_out = UseHandle hCompileLog
               , std_err = UseHandle hCompileLog
               }
    -- std_out and std_err are closed automatically
    -- so we don't need to take care of them.
    (_,_,_,ph) <- createProcess cp
    waitForProcess ph

-- | @withLock def action@ is the same as @withFileLock fpath def action@ with
--   @fpath@ being @"xmonad.${USERNAME}.lock"@ under your temporary directory.
--   Wrapping an action with more than one @withLock@ will not work.
--
--   See also: `withFileLock`, 'getTemporaryDirectory', 'getEffectiveUserName'
withLock :: a -> IO a -> IO a
withLock def action = do
    tmpDir <- getTemporaryDirectory
    -- https://ghc.haskell.org/trac/ghc/ticket/1487
    -- avoid using "getLoginName" here
    usr <- getEffectiveUserName
    let lockFile = tmpDir </> intercalate "." ["xmonad",usr,"lock"]
    withFileLock lockFile def action

-- | prevents an IO action from parallel execution by using a lock file.
--   @withFileLock fpath def action@ checks whether the file indicated by @fpath@
--   exists. And:
--
--   * returns @def@ if the file exists.
--   * creates @fpath@, executes the action, and deletes @fpath@ when the action
--     has completed. If @action@ has failed, @def@ will be returned instead.
--
--   Note that:
--
--   * the action will be protected by 'safeIO', meaning the lock file will be deleted
--     regardless of any error.
--   * No check on @fpath@ will be done by this function. Please make sure the lock file
--     does not exist.
--   * please prevent wrapping the action with same file lock multiple times,
--     in which case the action will never be executed.
withFileLock :: FilePath -> a -> IO a -> IO a
withFileLock fPath def action = do
    lock <- doesFileExist fPath
    if lock
      then skipCompile
      else doCompile
  where
    skipCompile = do
        putStrLn $ "Lock file " ++ fPath ++ " found, aborting ..."
        putStrLn   "Delete lock file to continue."
        return def
    doCompile = bracket_ (writeFile fPath "")
                         (removeFile fPath)
                         (safeIO def action)
