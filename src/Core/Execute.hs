{-# LANGUAGE PatternGuards #-}
module Core.Execute (execute) where

import Idris.AbsSyntax
import Idris.AbsSyntaxTree

import Core.TT
import Core.Evaluate
import Core.CaseTree

import Debug.Trace

import Util.DynamicLinker
import Util.System

import Control.Applicative hiding (Const)
import Control.Monad.Trans
import Control.Monad.Trans.State.Strict
import Control.Monad.Trans.Error
import Control.Monad
import Data.Maybe
import qualified Data.Map as M

import Foreign.LibFFI
import Foreign.C.String
import Foreign.Marshal.Alloc (free)
import Foreign.Ptr

import System.IO


data Lazy = Delayed ExecEnv Context Term | Forced ExecVal

data ExecState = ExecState { exec_thunks :: M.Map Int Lazy -- ^ Thunks - the result of evaluating "lazy" or calling lazy funcs
                           , exec_next_thunk :: Int -- ^ Ensure thunk key uniqueness
                           , exec_implicits :: Ctxt [PArg] -- ^ Necessary info on laziness from idris monad
                           , exec_dynamic_libs :: [DynamicLib] -- ^ Dynamic libs from idris monad
                           , exec_handles :: M.Map Int Handle -- ^ Opened files
                           , exec_next_handle :: Int -- ^ Ensure opened file key uniqueness
                           }

data ExecVal = EP NameType Name ExecVal
             | EV Int
             | EBind Name (Binder ExecVal) (ExecVal -> Exec ExecVal)
             | EApp ExecVal ExecVal
             | EType UExp
             | EErased
             | EConstant Const
--             | ETmp Int
             | EThunk Int
             | EHandle Int
               deriving Show

toTT :: ExecVal -> Exec Term
toTT (EP nt n ty) = (P nt n) <$> (toTT ty)
toTT (EV i) = return $ V i
toTT (EBind n b body) = do body' <- body $ EP Bound n EErased
                           b' <- fixBinder b
                           Bind n b' <$> toTT body'
    where fixBinder (Lam t)       = Lam   <$> toTT t
          fixBinder (Pi t)        = Pi    <$> toTT t
          fixBinder (Let t1 t2)   = Let   <$> toTT t1 <*> toTT t2
          fixBinder (NLet t1 t2)  = NLet  <$> toTT t1 <*> toTT t2
          fixBinder (Hole t)      = Hole  <$> toTT t
          fixBinder (GHole t)     = GHole <$> toTT t
          fixBinder (Guess t1 t2) = Guess <$> toTT t1 <*> toTT t2
          fixBinder (PVar t)      = PVar  <$> toTT t
          fixBinder (PVTy t)      = PVTy  <$> toTT t
toTT (EApp e1 e2) = do e1' <- toTT e1
                       e2' <- toTT e2
                       return $ App e1' e2'
toTT (EType u) = return $ TType u
toTT EErased = return Erased
toTT (EConstant c) = return (Constant c)
toTT (EThunk _) = return Erased
toTT (EHandle _) = return Erased

unApplyV :: ExecVal -> (ExecVal, [ExecVal])
unApplyV tm = ua [] tm
    where ua args (EApp f a) = ua (a:args) f
          ua args t = (t, args)

mkEApp :: ExecVal -> [ExecVal] -> ExecVal
mkEApp f [] = f
mkEApp f (a:args) = mkEApp (EApp f a) args

initState :: Idris ExecState
initState = do ist <- getIState
               return $ ExecState M.empty 0 (idris_implicits ist) (idris_dynamic_libs ist) M.empty 0

type Exec = ErrorT String (StateT ExecState IO)

runExec :: Exec a -> ExecState -> IO (Either String a)
runExec ex st = fst <$> runStateT (runErrorT ex) st

getExecState :: Exec ExecState
getExecState = lift get

putExecState :: ExecState -> Exec ()
putExecState = lift . put

execFail :: String -> Exec a
execFail = throwError

execIO :: IO a -> Exec a
execIO = lift . lift

delay :: ExecEnv -> Context -> Term -> Exec ExecVal
delay env ctxt tm =
    do st <- getExecState
       let i = exec_next_thunk st
       putExecState $ st { exec_thunks = M.insert i (Delayed env ctxt tm) (exec_thunks st)
                         , exec_next_thunk = exec_next_thunk st + 1
                         }
       return $ EThunk i

force :: Int -> Exec ExecVal
force i = do st <- getExecState
             case M.lookup i (exec_thunks st) of
               Just (Delayed env ctxt tm) -> do tm' <- doExec env ctxt tm
                                                case tm' of
                                                  EThunk i ->
                                                      do res <- force i
                                                         update res i
                                                         return res
                                                  _ -> do update tm' i
                                                          return tm'
               Just (Forced tm) -> return tm
               Nothing -> execFail "Tried to exec non-existing thunk. This is a bug!"
    where update :: ExecVal -> Int -> Exec ()
          update tm i = do est <- getExecState
                           putExecState $ est { exec_thunks = M.insert i (Forced tm) (exec_thunks est) }

tryForce :: ExecVal -> Exec ExecVal
tryForce (EThunk i) = force i
tryForce tm = return tm

execute :: Term -> Idris Term
execute tm = do est <- initState
                ctxt <- getContext
                res <- lift $ runExec (doExec [] ctxt tm >>= toTT) est
                case res of
                  Left err -> fail err
                  Right tm' -> return tm'

ioWrap :: ExecVal -> ExecVal
ioWrap tm = mkEApp (EP Ref (UN "prim__IO") EErased) [EErased, tm]

ioUnit :: ExecVal
ioUnit = ioWrap (EP Ref unitCon EErased)

type ExecEnv = [(Name, Binder ExecVal)]

doExec :: ExecEnv -> Context -> Term -> Exec ExecVal
doExec env ctxt p@(P Ref n ty) =
    do let val = lookupDef n ctxt
       case val of
         [Function _ tm] -> doExec env ctxt tm
         [TyDecl _ _] -> return (EP Ref n EErased) -- abstract def
         [Operator tp arity op] -> return (EP Ref n EErased) -- will be special-cased later
         [CaseOp _ _ _ _ _ [] (STerm tm) _ _] -> -- nullary fun
             doExec env ctxt tm
         [CaseOp _ _ _ _ _ ns sc _ _] -> return (EP Ref n EErased)
         thing -> trace (take 200 $ "got to " ++ show thing ++ " lookup up " ++ show n) $ undefined
doExec env ctxt p@(P Bound n ty) =
  case lookup n env of
    Nothing -> execFail "not found"
    Just (Let _ tm) -> return tm
    Just b -> execFail $ "Unknown binder " ++ show b
doExec env ctxt (P (DCon a b) n _) = return (EP (DCon a b) n EErased)
doExec env ctxt (P (TCon a b) n _) = return (EP (TCon a b) n EErased)
doExec env ctxt v@(V i) | i < length env = do let binder = env !! i
                                              case binder of
                                                (_, (Let t v)) -> return v
                                                (_, (NLet t v)) -> return v
                                                (n, b) -> doExec env ctxt (P Bound n Erased)
                        | otherwise      = execFail "env too small"
doExec env ctxt (Bind n (Let t v) body) = do v' <- doExec env ctxt v
                                             doExec ((n, Let EErased v'):env) ctxt body
doExec env ctxt (Bind n (NLet t v) body) = trace "NLet" $ undefined
doExec env ctxt tm@(Bind n b body) = return $
                                     EBind n (fmap (\_->EErased) b)
                                           (\arg -> doExec ((n, Let EErased arg):env) ctxt body)
doExec env ctxt a@(App _ _) = execApp env ctxt (unApply a)
doExec env ctxt (Constant c) = return (EConstant c)
doExec env ctxt (Proj tm i) = let (x, xs) = unApply tm in
                              doExec env ctxt ((x:xs) !! i)
doExec env ctxt Erased = return EErased
doExec env ctxt Impossible = fail "Tried to execute an impossible case"
doExec env ctxt (TType u) = return (EType u)

execApp :: ExecEnv -> Context -> (Term, [Term]) -> Exec ExecVal
execApp env ctxt (f, args) = do newF <- doExec env ctxt f
                                laziness <- (getLaziness newF) >>= return . (++ repeat False)
                                newArgs <- mapM argExec (zip args laziness)
                                trace (take 1000 (show newF) ++ " " ++ take 2000 (show newArgs)) $ return ()
                                execApp' env ctxt newF newArgs
    where getLaziness (EP _ (UN "lazy") _) = return [True]
          getLaziness (EP _ n _) = do est <- getExecState
                                      let argInfo = exec_implicits est
                                      case lookupCtxtName n argInfo of
                                        [] -> return (repeat False)
                                        [ps] -> return $ map lazyarg (snd ps)
                                        many -> execFail $ "Ambiguous " ++ show n ++ ", found " ++ (take 200 $ show many)
          getLaziness _ = return (repeat False) -- ok due to zip above
          argExec :: (Term, Bool) -> Exec ExecVal
          argExec (tm, False) = doExec env ctxt tm
          argExec (tm, True) = delay env ctxt tm


execApp' :: ExecEnv -> Context -> ExecVal -> [ExecVal] -> Exec ExecVal
execApp' env ctxt v [] = return v -- no args is just a constant! can result from function calls
execApp' env ctxt (EP _ (UN "unsafePerformIO") _) (ty:action:rest) | (prim__IO, [ty', v]) <- unApplyV action =
    execApp' env ctxt v rest

-- Special cases arising from not having access to the C RTS in the interpreter

execApp' env ctxt (EP _ (UN "mkForeign") _) (_:fn:EConstant (Str arg):rest)
    | Just (FFun "putStr" _ _) <- foreignFromTT fn = do execIO (putStr arg)
                                                        execApp' env ctxt ioUnit rest
execApp' env ctxt (EP _ (UN "mkForeign") _) (_:fn:EConstant (Str f):EConstant (Str mode):rest)
    | Just (FFun "fileOpen" _ _) <- foreignFromTT fn = do m <- case mode of
                                                                 "r" -> return ReadMode
                                                                 "w" -> return WriteMode
                                                                 "a" -> return AppendMode
                                                                 "rw" -> return ReadWriteMode
                                                                 "wr" -> return ReadWriteMode
                                                                 "r+" -> return ReadWriteMode
                                                                 _ -> execFail ("Invalid mode for " ++ f ++ ": " ++ mode)
                                                          h <- execIO $ openFile f m
                                                          h' <- handle h
                                                          execApp' env ctxt (ioWrap h') rest

execApp' env ctxt (EP _ (UN "mkForeign") _) (_:fn:fh:rest)
    | Just (FFun "fileEOF" _ _) <- foreignFromTT fn = do h <- unHandle fh
                                                         eofp <- execIO $ hIsEOF h
                                                         let res = ioWrap (EConstant (I $ if eofp then 1 else 0))
                                                         trace ("feof was " ++ show eofp) $ return ()
                                                         execApp' env ctxt res rest


execApp' env ctxt f@(EP _ (UN "mkForeign") _) args@(ty:fn:xs) | Just (FFun _ argTs retT) <- foreignFromTT fn
                                                              , length xs >= length argTs =
    do res <- stepForeign (ty:fn:take (length argTs) xs)
       case res of
         Nothing -> fail "Could not call foreign function"
         Just r -> return (mkEApp r (drop (length argTs) xs))
                                                             | otherwise = return (mkEApp f args)

execApp' env ctxt f@(EP _ n _) args =
    do let val = lookupDef n ctxt
       case val of
         [Function _ tm] -> fail "should already have been eval'd"
         [TyDecl nt ty] -> return $ mkEApp f args
         [Operator tp arity op] ->
             case getOp n (take arity args) of
               Just res -> do r <- res
                              execApp' env ctxt r (drop arity args)
               Nothing -> return (mkEApp f args)
         [CaseOp _ _ _ _ _ [] (STerm tm) _ _] -> -- nullary fun
             do rhs <- doExec env ctxt tm
                execApp' env ctxt rhs args
         [CaseOp _ _ _ _ _  ns sc _ _] ->
             do res <- execCase env ctxt ns sc args
                return $ fromMaybe (mkEApp f args) res
         thing -> return $ mkEApp f args
    where getOp :: Name -> [ExecVal] -> Maybe (Exec ExecVal)
          getOp (UN "prim__concat") [EConstant (Str s1), EConstant (Str s2)] =
              Just . return . EConstant . Str $ s1 ++ s2
          getOp (UN "prim__eqInt") [EConstant (I i1), EConstant (I i2)] =
              Just . return . EConstant . I $ if i1 == i2 then 1 else 0
          getOp (UN "prim__ltInt") [EConstant (I i1), EConstant (I i2)] =
              Just . return . EConstant . I $ if i1 < i2 then 1 else 0
          getOp (UN "prim__subInt") [EConstant (I i1), EConstant (I i2)] =
              Just .  return . EConstant . I $ i1 - i2
          getOp (UN "prim__readString") [EP _ (UN "prim__stdin") _] =
              Just $ do line <- execIO getLine
                        return (EConstant (Str line))
          getOp (UN "prim__readString") [ptr] =
              Just $ do h <- unHandle ptr
                        contents <- execIO $ hGetLine h
                        return $ ioWrap (EConstant (Str contents))
          getOp _ _ = Nothing
execApp' env ctxt bnd@(EBind n b body) (arg:args) = do ret <- body arg
                                                       execApp' env ctxt ret args

execApp' env ctxt f args = return (mkEApp f args)


-- | Overall wrapper for case tree execution. If there are enough arguments, it takes them,
-- evaluates them, then begins the checks for matching cases.
execCase :: ExecEnv -> Context -> [Name] -> SC -> [ExecVal] -> Exec (Maybe ExecVal)
execCase env ctxt ns sc args =
    let arity = length ns in
    if arity <= length args
    then do -- args' <- mapM tryForce (take arity args)
            let amap = zip ns args
            caseRes <- execCase' env ctxt amap sc
            case caseRes of
              Just res -> Just <$> execApp' (map (\(n, tm) -> (n, Let EErased tm)) amap ++ env) ctxt res (drop arity args)
              Nothing -> return Nothing
    else return Nothing

-- | Take bindings and a case tree and examines them, executing the matching case if possible.
execCase' :: ExecEnv -> Context -> [(Name, ExecVal)] -> SC -> Exec (Maybe ExecVal)
execCase' env ctxt amap (UnmatchedCase _) = trace "Unmatched" $ return Nothing
execCase' env ctxt amap (STerm tm) =
    Just <$> doExec (map (\(n, v) -> (n, Let EErased v)) amap ++ env) ctxt tm
execCase' env ctxt amap (Case n alts) | Just tm <- lookup n amap =
    do tm' <- tryForce tm
       case chooseAlt tm alts of
         Just (newCase, newBindings) ->
             let amap' = newBindings ++ (filter (\(x,_) -> not (elem x (map fst newBindings))) amap) in
             execCase' env ctxt amap' newCase
         Nothing -> return Nothing

chooseAlt :: ExecVal -> [CaseAlt] -> Maybe (SC, [(Name, ExecVal)])
chooseAlt _ (DefaultCase sc : alts) = Just (sc, [])
chooseAlt (EConstant c) (ConstCase c' sc : alts) | c == c' = Just (sc, [])
chooseAlt tm (ConCase n i ns sc : alts) | ((EP _ cn _), args) <- unApplyV tm
                                        , cn == n = Just (sc, zip ns args)
                                        | otherwise = chooseAlt tm alts
chooseAlt tm (_:alts) = chooseAlt tm alts
chooseAlt _ [] = Nothing

data FTy = FInt | FFloat | FChar | FString | FPtr | FUnit deriving (Show, Read)

idrisType :: FTy -> ExecVal
idrisType FUnit = EP Ref unitTy EErased
idrisType ft = EConstant (idr ft)
    where idr FInt = IType
          idr FFloat = FlType
          idr FChar = ChType
          idr FString = StrType
          idr FPtr = PtrType

data Foreign = FFun String [FTy] FTy deriving Show

-- | A representation of Ptr values, which otherwise don't work in TT
ptrCon :: Name
ptrCon = MN 0 "__Ptr"

-- | Convert a Haskell pointer to a Ptr term in TT
ptr :: Ptr a -> ExecVal
ptr p = EApp (EP (DCon 1 0) ptrCon EErased) (EConstant (I (addr p)))
    where addr p = p `minusPtr` nullPtr

-- | Convert a Ptr term in TT to a Haskell pointer
unPtr :: ExecVal -> Maybe (Ptr a)
unPtr (EApp (EP _ con _) (EConstant (I addr))) | con == ptrCon = Just (unAddr addr)
    where unAddr a = nullPtr `plusPtr` a
unPtr _ = Nothing

handleCon :: Name
handleCon = MN 0 "__Handle"

-- | Convert a Haskell file handle to a handle term in TT (an int)
handle :: Handle -> Exec ExecVal
handle h = do est <- getExecState
              let i = exec_next_handle est
              putExecState $ est { exec_next_handle = exec_next_handle est + 1
                                 , exec_handles = M.insert i h (exec_handles est)
                                 }
              return $ EHandle i

unHandle :: ExecVal -> Exec Handle
unHandle (EHandle i) =
    do est <- getExecState
       case M.lookup i (exec_handles est) of
         Just h -> return h
         Nothing -> execFail "Bad handle ID"
unHandle _ = execFail "Not a handle"

call :: Foreign -> [ExecVal] -> Exec (Maybe ExecVal)
call (FFun name argTypes retType) args =
    do fn <- findForeign name
       case fn of
         Nothing -> return Nothing
         Just f -> do res <- call' f args retType
                      return . Just $ mkEApp (EP Ref (UN "prim__IO") EErased) [idrisType retType, res]
    where call' :: ForeignFun -> [ExecVal] -> FTy -> Exec ExecVal
          call' (Fun _ h) args FInt = do res <- execIO $ callFFI h retCInt (prepArgs args)
                                         return (EConstant (I (fromIntegral res)))
          call' (Fun _ h) args FFloat = do res <- execIO $ callFFI h retCDouble (prepArgs args)
                                           return (EConstant (Fl (realToFrac res)))
          call' (Fun _ h) args FChar = do res <- execIO $ callFFI h retCChar (prepArgs args)
                                          return (EConstant (Ch (castCCharToChar res)))
          call' (Fun _ h) args FString = do res <- execIO $ callFFI h retCString (prepArgs args)
                                            hStr <- execIO $ peekCString res
--                                            lift $ free res
                                            return (EConstant (Str hStr))

          call' (Fun _ h) args FPtr = do res <- execIO $ callFFI h (retPtr retVoid) (prepArgs args)
                                         return (ptr res)
          call' (Fun _ h) args FUnit = do res <- execIO $ callFFI h retVoid (prepArgs args)
                                          return (EP Ref unitCon EErased)
--          call' (Fun _ h) args other = fail ("Unsupported foreign return type " ++ show other)


          prepArgs = map prepArg
          prepArg (EConstant (I i)) = argCInt (fromIntegral i)
          prepArg (EConstant (Fl f)) = argCDouble (realToFrac f)
          prepArg (EConstant (Ch c)) = argCChar (castCharToCChar c) -- FIXME - castCharToCChar only safe for first 256 chars
          prepArg (EConstant (Str s)) = argString s
          prepArg ptr | Just p <- unPtr ptr = argPtr p
          prepArg other = trace ("Could not use " ++ take 100 (show other) ++ " as FFI arg.") undefined



foreignFromTT :: ExecVal -> Maybe Foreign
foreignFromTT t = case (unApplyV t) of
                    (_, [(EConstant (Str name)), args, ret]) ->
                        do argTy <- unEList args
                           argFTy <- sequence $ map getFTy argTy
                           retFTy <- getFTy ret
                           return $ FFun name argFTy retFTy
                    _ -> trace "failed to construct ffun" Nothing

getFTy :: ExecVal -> Maybe FTy
getFTy (EP _ (UN t) _) =
    case t of
      "FInt"    -> Just FInt
      "FFloat"  -> Just FFloat
      "FChar"   -> Just FChar
      "FString" -> Just FString
      "FPtr"    -> Just FPtr
      "FUnit"   -> Just FUnit
      _         -> Nothing
getFTy _ = Nothing

unList :: Term -> Maybe [Term]
unList tm = case unApply tm of
              (nil, [_]) -> Just []
              (cons, ([_, x, xs])) ->
                  do rest <- unList xs
                     return $ x:rest
              (f, args) -> Nothing

unEList :: ExecVal -> Maybe [ExecVal]
unEList tm = case unApplyV tm of
               (nil, [_]) -> Just []
               (cons, ([_, x, xs])) ->
                   do rest <- unEList xs
                      return $ x:rest
               (f, args) -> Nothing


toConst :: Term -> Maybe Const
toConst (Constant c) = Just c
toConst _ = Nothing

stepForeign :: [ExecVal] -> Exec (Maybe ExecVal)
stepForeign (ty:fn:args) = do let ffun = foreignFromTT fn
                              f' <- case (call <$> ffun) of
                                      Just f -> f args
                                      Nothing -> return Nothing
                              return f'
stepForeign _ = fail "Tried to call foreign function that wasn't mkForeign"

mapMaybeM :: Monad m => (a -> m (Maybe b)) -> [a] -> m [b]
mapMaybeM f [] = return []
mapMaybeM f (x:xs) = do rest <- mapMaybeM f xs
                        x' <- f x
                        case x' of
                          Just x'' -> return (x'':rest)
                          Nothing -> return rest

findForeign :: String -> Exec (Maybe ForeignFun)
findForeign fn = do est <- getExecState
                    let libs = exec_dynamic_libs est
                    fns <- mapMaybeM getFn libs
                    case fns of
                      [f] -> return (Just f)
                      [] -> do execIO . putStrLn $ "Symbol \"" ++ fn ++ "\" not found"
                               return Nothing
                      fs -> do execIO . putStrLn $ "Symbol \"" ++ fn ++ "\" is ambiguous. Found " ++
                                                   show (length fs) ++ " occurrences."
                               return Nothing
    where getFn lib = execIO $ catchIO (tryLoadFn fn lib) (\_ -> return Nothing)
