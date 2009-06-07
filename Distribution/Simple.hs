-----------------------------------------------------------------------------
-- |
-- Module      :  Distribution.Simple
-- Copyright   :  Isaac Jones 2003-2005
--
-- Maintainer  :  cabal-devel@haskell.org
-- Portability :  portable
--
-- This is the command line front end to the Simple build system. When given
-- the parsed command-line args and package information, is able to perform
-- basic commands like configure, build, install, register, etc.
--
-- This module exports the main functions that Setup.hs scripts use. It
-- re-exports the 'UserHooks' type, the standard entry points like
-- 'defaultMain' and 'defaultMainWithHooks' and the predefined sets of
-- 'UserHooks' that custom @Setup.hs@ scripts can extend to add their own
-- behaviour.
--
-- This module isn't called \"Simple\" because it's simple.  Far from
-- it.  It's called \"Simple\" because it does complicated things to
-- simple software.
--
-- The original idea was that there could be different build systems that all
-- presented the same compatible command line interfaces. There is still a
-- "Distribution.Make" system but in practice no packages use it.

{- All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    * Neither the name of Isaac Jones nor the names of other
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. -}

module Distribution.Simple (
        module Distribution.Package,
        module Distribution.Version,
        module Distribution.License,
        module Distribution.Simple.Compiler,
        module Language.Haskell.Extension,
        -- * Simple interface
        defaultMain, defaultMainNoRead, defaultMainArgs,
        -- * Customization
        UserHooks(..), Args,
        defaultMainWithHooks, defaultMainWithHooksArgs,
        -- ** Standard sets of hooks
        simpleUserHooks,
        autoconfUserHooks,
        defaultUserHooks, emptyUserHooks,
        -- ** Utils
        defaultHookedPackageDesc
  ) where

-- local
import Distribution.Simple.Compiler hiding (Flag)
import Distribution.Simple.UserHooks
import Distribution.Package --must not specify imports, since we're exporting moule.
import Distribution.PackageDescription
         ( PackageDescription(..), GenericPackageDescription
         , updatePackageDescription, hasLibs
         , HookedBuildInfo, emptyHookedBuildInfo )
import Distribution.PackageDescription.Parse
         ( readPackageDescription, readHookedBuildInfo )
import Distribution.PackageDescription.Configuration
         ( flattenPackageDescription )
import Distribution.Simple.Program
         ( defaultProgramConfiguration, addKnownPrograms, builtinPrograms
         , restoreProgramConfiguration, reconfigurePrograms )
import Distribution.Simple.PreProcess (knownSuffixHandlers, PPSuffixHandler)
import Distribution.Simple.Setup
import Distribution.Simple.Command

import Distribution.Simple.Build        ( build )
import Distribution.Simple.SrcDist      ( sdist )
import Distribution.Simple.Register
         ( register, unregister, removeRegScripts )

import Distribution.Simple.Configure
         ( getPersistBuildConfig, maybeGetPersistBuildConfig
         , writePersistBuildConfig, checkPersistBuildConfig
         , configure, checkForeignDeps )

import Distribution.Simple.LocalBuildInfo ( LocalBuildInfo(..) )
import Distribution.Simple.BuildPaths ( srcPref)
import Distribution.Simple.Install (install)
import Distribution.Simple.Haddock (haddock, hscolour)
import Distribution.Simple.Utils
         (die, notice, info, warn, setupMessage, chattyTry,
          defaultPackageDesc, defaultHookedPackageDesc,
          rawSystemExit, cabalVersion, topHandler )
import Distribution.Verbosity
import Language.Haskell.Extension
import Distribution.Version
import Distribution.License
import Distribution.Text
         ( display )

-- Base
import System.Environment(getArgs,getProgName)
import System.Directory(removeFile, doesFileExist,
                        doesDirectoryExist, removeDirectoryRecursive)
import System.Exit

import Control.Monad   (when)
import Data.List       (intersperse, unionBy)

-- | A simple implementation of @main@ for a Cabal setup script.
-- It reads the package description file using IO, and performs the
-- action specified on the command line.
defaultMain :: IO ()
defaultMain = getArgs >>= defaultMainHelper simpleUserHooks

-- | A version of 'defaultMain' that is passed the command line
-- arguments, rather than getting them from the environment.
defaultMainArgs :: [String] -> IO ()
defaultMainArgs = defaultMainHelper simpleUserHooks

-- | A customizable version of 'defaultMain'.
defaultMainWithHooks :: UserHooks -> IO ()
defaultMainWithHooks hooks = getArgs >>= defaultMainHelper hooks

-- | A customizable version of 'defaultMain' that also takes the command
-- line arguments.
defaultMainWithHooksArgs :: UserHooks -> [String] -> IO ()
defaultMainWithHooksArgs = defaultMainHelper

-- | Like 'defaultMain', but accepts the package description as input
-- rather than using IO to read it.
defaultMainNoRead :: GenericPackageDescription -> IO ()
defaultMainNoRead pkg_descr =
  getArgs >>=
  defaultMainHelper simpleUserHooks { readDesc = return (Just pkg_descr) }

defaultMainHelper :: UserHooks -> Args -> IO ()
defaultMainHelper hooks args = topHandler $
  case commandsRun globalCommand commands args of
    CommandHelp   help                 -> printHelp help
    CommandList   opts                 -> printOptionsList opts
    CommandErrors errs                 -> printErrors errs
    CommandReadyToGo (flags, commandParse)  ->
      case commandParse of
        _ | fromFlag (globalVersion flags)        -> printVersion
          | fromFlag (globalNumericVersion flags) -> printNumericVersion
        CommandHelp     help           -> printHelp help
        CommandList     opts           -> printOptionsList opts
        CommandErrors   errs           -> printErrors errs
        CommandReadyToGo action        -> action

  where
    printHelp help = getProgName >>= putStr . help
    printOptionsList = putStr . unlines
    printErrors errs = do
      putStr (concat (intersperse "\n" errs))
      exitWith (ExitFailure 1)
    printNumericVersion = putStrLn $ display cabalVersion
    printVersion        = putStrLn $ "Cabal library version "
                                  ++ display cabalVersion

    progs = addKnownPrograms (hookedPrograms hooks) defaultProgramConfiguration
    commands =
      [configureCommand progs `commandAddAction` configureAction    hooks
      ,buildCommand     progs `commandAddAction` buildAction        hooks
      ,installCommand         `commandAddAction` installAction      hooks
      ,copyCommand            `commandAddAction` copyAction         hooks
      ,haddockCommand         `commandAddAction` haddockAction      hooks
      ,cleanCommand           `commandAddAction` cleanAction        hooks
      ,sdistCommand           `commandAddAction` sdistAction        hooks
      ,hscolourCommand        `commandAddAction` hscolourAction     hooks
      ,registerCommand        `commandAddAction` registerAction     hooks
      ,unregisterCommand      `commandAddAction` unregisterAction   hooks
      ,testCommand            `commandAddAction` testAction         hooks
      ]

-- | Combine the preprocessors in the given hooks with the
-- preprocessors built into cabal.
allSuffixHandlers :: UserHooks
                  -> [PPSuffixHandler]
allSuffixHandlers hooks
    = overridesPP (hookedPreProcessors hooks) knownSuffixHandlers
    where
      overridesPP :: [PPSuffixHandler] -> [PPSuffixHandler] -> [PPSuffixHandler]
      overridesPP = unionBy (\x y -> fst x == fst y)

configureAction :: UserHooks -> ConfigFlags -> Args -> IO ()
configureAction hooks flags args = do
                let distPref = fromFlag $ configDistPref flags
                pbi <- preConf hooks args flags

                (mb_pd_file, pkg_descr0) <- confPkgDescr

                --    get_pkg_descr (configVerbosity flags')
                --let pkg_descr = updatePackageDescription pbi pkg_descr0
                let epkg_descr = (pkg_descr0, pbi)

                --(warns, ers) <- sanityCheckPackage pkg_descr
                --errorOut (configVerbosity flags') warns ers

                localbuildinfo0 <- confHook hooks epkg_descr flags

                -- remember the .cabal filename if we know it
                let localbuildinfo = localbuildinfo0{ pkgDescrFile = mb_pd_file }
                writePersistBuildConfig distPref localbuildinfo

                let pkg_descr = localPkgDescr localbuildinfo
                postConf hooks args flags pkg_descr localbuildinfo
              where
                verbosity = fromFlag (configVerbosity flags)
                confPkgDescr :: IO (Maybe FilePath, GenericPackageDescription)
                confPkgDescr = do
                  mdescr <- readDesc hooks
                  case mdescr of
                    Just descr -> return (Nothing, descr)
                    Nothing -> do
                      pdfile <- defaultPackageDesc verbosity
                      descr  <- readPackageDescription verbosity pdfile
                      return (Just pdfile, descr)

buildAction :: UserHooks -> BuildFlags -> Args -> IO ()
buildAction hooks flags args = do
  let distPref  = fromFlag $ buildDistPref flags
      verbosity = fromFlag $ buildVerbosity flags

  lbi <- getBuildConfig hooks distPref
  progs <- reconfigurePrograms verbosity
             (buildProgramPaths flags)
             (buildProgramArgs flags)
             (withPrograms lbi)

  hookedAction preBuild buildHook postBuild
               (return lbi { withPrograms = progs })
               hooks flags args

hscolourAction :: UserHooks -> HscolourFlags -> Args -> IO ()
hscolourAction hooks flags args
    = do let distPref = fromFlag $ hscolourDistPref flags
         hookedAction preHscolour hscolourHook postHscolour
                      (getBuildConfig hooks distPref)
                      hooks flags args

haddockAction :: UserHooks -> HaddockFlags -> Args -> IO ()
haddockAction hooks flags args = do
  let distPref  = fromFlag $ haddockDistPref flags
      verbosity = fromFlag $ haddockVerbosity flags

  lbi <- getBuildConfig hooks distPref
  progs <- reconfigurePrograms verbosity
             (haddockProgramPaths flags)
             (haddockProgramArgs flags)
             (withPrograms lbi)

  hookedAction preHaddock haddockHook postHaddock
               (return lbi { withPrograms = progs })
               hooks flags args

cleanAction :: UserHooks -> CleanFlags -> Args -> IO ()
cleanAction hooks flags args = do
                pbi <- preClean hooks args flags

                pdfile <- defaultPackageDesc verbosity
                ppd <- readPackageDescription verbosity pdfile
                let pkg_descr0 = flattenPackageDescription ppd
                let pkg_descr = updatePackageDescription pbi pkg_descr0

                cleanHook hooks pkg_descr () hooks flags
                postClean hooks args flags pkg_descr ()
  where verbosity = fromFlag (cleanVerbosity flags)

copyAction :: UserHooks -> CopyFlags -> Args -> IO ()
copyAction hooks flags args
    = do let distPref = fromFlag $ copyDistPref flags
         hookedAction preCopy copyHook postCopy
                      (getBuildConfig hooks distPref)
                      hooks flags args

installAction :: UserHooks -> InstallFlags -> Args -> IO ()
installAction hooks flags args
    = do let distPref = fromFlag $ installDistPref flags
         hookedAction preInst instHook postInst
                      (getBuildConfig hooks distPref)
                      hooks flags args

sdistAction :: UserHooks -> SDistFlags -> Args -> IO ()
sdistAction hooks flags args = do
                let distPref = fromFlag $ sDistDistPref flags
                pbi <- preSDist hooks args flags

                mlbi <- maybeGetPersistBuildConfig distPref
                pdfile <- defaultPackageDesc verbosity
                ppd <- readPackageDescription verbosity pdfile
                let pkg_descr0 = flattenPackageDescription ppd
                let pkg_descr = updatePackageDescription pbi pkg_descr0

                sDistHook hooks pkg_descr mlbi hooks flags
                postSDist hooks args flags pkg_descr mlbi
  where verbosity = fromFlag (sDistVerbosity flags)

testAction :: UserHooks -> TestFlags -> Args -> IO ()
testAction hooks flags args = do
                let distPref = fromFlag $ testDistPref flags
                localbuildinfo <- getBuildConfig hooks distPref
                let pkg_descr = localPkgDescr localbuildinfo
                runTests hooks args False pkg_descr localbuildinfo

registerAction :: UserHooks -> RegisterFlags -> Args -> IO ()
registerAction hooks flags args
    = do let distPref = fromFlag $ regDistPref flags
         hookedAction preReg regHook postReg
                      (getBuildConfig hooks distPref)
                      hooks flags args

unregisterAction :: UserHooks -> RegisterFlags -> Args -> IO ()
unregisterAction hooks flags args
    = do let distPref = fromFlag $ regDistPref flags
         hookedAction preUnreg unregHook postUnreg
                      (getBuildConfig hooks distPref)
                      hooks flags args

hookedAction :: (UserHooks -> Args -> flags -> IO HookedBuildInfo)
        -> (UserHooks -> PackageDescription -> LocalBuildInfo
                      -> UserHooks -> flags -> IO ())
        -> (UserHooks -> Args -> flags -> PackageDescription
                      -> LocalBuildInfo -> IO ())
        -> IO LocalBuildInfo
        -> UserHooks -> flags -> Args -> IO ()
hookedAction pre_hook cmd_hook post_hook get_build_config hooks flags args = do
   pbi <- pre_hook hooks args flags
   localbuildinfo <- get_build_config
   let pkg_descr0 = localPkgDescr localbuildinfo
   --pkg_descr0 <- get_pkg_descr (get_verbose flags)
   let pkg_descr = updatePackageDescription pbi pkg_descr0
   -- XXX: should we write the modified package descr back to the
   -- localbuildinfo?
   cmd_hook hooks pkg_descr localbuildinfo hooks flags
   post_hook hooks args flags pkg_descr localbuildinfo

getBuildConfig :: UserHooks -> FilePath -> IO LocalBuildInfo
getBuildConfig hooks distPref = do
  lbi <- getPersistBuildConfig distPref
  case pkgDescrFile lbi of
    Nothing -> return ()
    Just pkg_descr_file -> checkPersistBuildConfig distPref pkg_descr_file
  return lbi {
    withPrograms = restoreProgramConfiguration
                     (builtinPrograms ++ hookedPrograms hooks)
                     (withPrograms lbi)
  }

-- --------------------------------------------------------------------------
-- Cleaning

clean :: PackageDescription -> CleanFlags -> IO ()
clean pkg_descr flags = do
    let distPref = fromFlag $ cleanDistPref flags
    notice verbosity "cleaning..."

    maybeConfig <- if fromFlag (cleanSaveConf flags)
                     then maybeGetPersistBuildConfig distPref
                     else return Nothing

    -- remove the whole dist/ directory rather than tracking exactly what files
    -- we created in there.
    chattyTry "removing dist/" $ do
      exists <- doesDirectoryExist distPref
      when exists (removeDirectoryRecursive distPref)

    -- these live in the top level dir so must be removed separately
    removeRegScripts

    -- Any extra files the user wants to remove
    mapM_ removeFileOrDirectory (extraTmpFiles pkg_descr)

    -- If the user wanted to save the config, write it back
    maybe (return ()) (writePersistBuildConfig distPref) maybeConfig

  where
        removeFileOrDirectory :: FilePath -> IO ()
        removeFileOrDirectory fname = do
            isDir <- doesDirectoryExist fname
            isFile <- doesFileExist fname
            if isDir then removeDirectoryRecursive fname
              else if isFile then removeFile fname
              else return ()
        verbosity = fromFlag (cleanVerbosity flags)

-- --------------------------------------------------------------------------
-- Default hooks

-- | Hooks that correspond to a plain instantiation of the
-- \"simple\" build system
simpleUserHooks :: UserHooks
simpleUserHooks =
    emptyUserHooks {
       confHook  = configure,
       postConf  = finalChecks,
       buildHook = defaultBuildHook,
       copyHook  = \desc lbi _ f -> install desc lbi f, -- has correct 'copy' behavior with params
       instHook  = defaultInstallHook,
       sDistHook = \p l h f -> sdist p l f srcPref (allSuffixHandlers h),
       cleanHook = \p _ _ f -> clean p f,
       hscolourHook = \p l h f -> hscolour p l (allSuffixHandlers h) f,
       haddockHook  = \p l h f -> haddock  p l (allSuffixHandlers h) f,
       regHook   = defaultRegHook,
       unregHook = \p l _ f -> unregister p l f
      }
  where
    finalChecks _args flags pkg_descr lbi =
      checkForeignDeps pkg_descr lbi verbosity
      where
        verbosity = fromFlag (configVerbosity flags)

-- | Basic autoconf 'UserHooks':
--
-- * on non-Windows systems, 'postConf' runs @.\/configure@, if present.
--
-- * the pre-hooks 'preBuild', 'preClean', 'preCopy', 'preInst',
--   'preReg' and 'preUnreg' read additional build information from
--   /package/@.buildinfo@, if present.
--
-- Thus @configure@ can use local system information to generate
-- /package/@.buildinfo@ and possibly other files.

-- FIXME: do something sensible for windows, or do nothing in postConf.

{-# DEPRECATED defaultUserHooks
     "Use simpleUserHooks or autoconfUserHooks, unless you need Cabal-1.2\n             compatibility in which case you must stick with defaultUserHooks" #-}
defaultUserHooks :: UserHooks
defaultUserHooks = autoconfUserHooks {
          confHook = \pkg flags -> do
                       let verbosity = fromFlag (configVerbosity flags)
                       warn verbosity $
                         "defaultUserHooks in Setup script is deprecated."
                       confHook autoconfUserHooks pkg flags,
          postConf = oldCompatPostConf
    }
    -- This is the annoying old version that only runs configure if it exists.
    -- It's here for compatibility with existing Setup.hs scripts. See:
    -- http://hackage.haskell.org/trac/hackage/ticket/165
    where oldCompatPostConf args flags pkg_descr lbi
              = do let verbosity = fromFlag (configVerbosity flags)
                   noExtraFlags args
                   confExists <- doesFileExist "configure"
                   when confExists $
                       rawSystemExit verbosity "sh" $
                       "configure" : configureArgs backwardsCompatHack flags

                   pbi <- getHookedBuildInfo verbosity
                   let pkg_descr' = updatePackageDescription pbi pkg_descr
                   postConf simpleUserHooks args flags pkg_descr' lbi

          backwardsCompatHack = True

autoconfUserHooks :: UserHooks
autoconfUserHooks
    = simpleUserHooks
      {
       postConf    = defaultPostConf,
       preBuild    = readHook buildVerbosity,
       preClean    = readHook cleanVerbosity,
       preCopy     = readHook copyVerbosity,
       preInst     = readHook installVerbosity,
       preHscolour = readHook hscolourVerbosity,
       preHaddock  = readHook haddockVerbosity,
       preReg      = readHook regVerbosity,
       preUnreg    = readHook regVerbosity
      }
    where defaultPostConf :: Args -> ConfigFlags -> PackageDescription -> LocalBuildInfo -> IO ()
          defaultPostConf args flags pkg_descr lbi
              = do let verbosity = fromFlag (configVerbosity flags)
                   noExtraFlags args
                   confExists <- doesFileExist "configure"
                   if confExists
                     then rawSystemExit verbosity "sh" $
                            "configure"
                          : configureArgs backwardsCompatHack flags
                     else die "configure script not found."

                   pbi <- getHookedBuildInfo verbosity
                   let pkg_descr' = updatePackageDescription pbi pkg_descr
                   postConf simpleUserHooks args flags pkg_descr' lbi

          backwardsCompatHack = False

          readHook :: (a -> Flag Verbosity) -> Args -> a -> IO HookedBuildInfo
          readHook get_verbosity a flags = do
              noExtraFlags a
              getHookedBuildInfo verbosity
            where
              verbosity = fromFlag (get_verbosity flags)

getHookedBuildInfo :: Verbosity -> IO HookedBuildInfo
getHookedBuildInfo verbosity = do
  maybe_infoFile <- defaultHookedPackageDesc
  case maybe_infoFile of
    Nothing       -> return emptyHookedBuildInfo
    Just infoFile -> do
      info verbosity $ "Reading parameters from " ++ infoFile
      readHookedBuildInfo verbosity infoFile

defaultInstallHook :: PackageDescription -> LocalBuildInfo
                   -> UserHooks -> InstallFlags -> IO ()
defaultInstallHook pkg_descr localbuildinfo _ flags = do
  let copyFlags = defaultCopyFlags {
                      copyDistPref   = installDistPref flags,
                      copyDest       = toFlag NoCopyDest,
                      copyVerbosity  = installVerbosity flags
                  }
  install pkg_descr localbuildinfo copyFlags
  let registerFlags = defaultRegisterFlags {
                          regDistPref  = installDistPref flags,
                          regInPlace   = installInPlace flags,
                          regPackageDB = installPackageDB flags,
                          regVerbosity = installVerbosity flags
                      }
  when (hasLibs pkg_descr) $ register pkg_descr localbuildinfo registerFlags

defaultBuildHook :: PackageDescription -> LocalBuildInfo
        -> UserHooks -> BuildFlags -> IO ()
defaultBuildHook pkg_descr localbuildinfo hooks flags =
  build pkg_descr localbuildinfo flags (allSuffixHandlers hooks)

defaultRegHook :: PackageDescription -> LocalBuildInfo
        -> UserHooks -> RegisterFlags -> IO ()
defaultRegHook pkg_descr localbuildinfo _ flags =
    if hasLibs pkg_descr
    then register pkg_descr localbuildinfo flags
    else setupMessage verbosity
           "Package contains no library to register:" (packageId pkg_descr)
  where verbosity = fromFlag (regVerbosity flags)