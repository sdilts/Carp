module Expand (expandAll, replaceSourceInfoOnXObj) where

import Control.Monad.State.Lazy (StateT(..), runStateT, liftIO, modify, get, put)
import Control.Monad.State
import Debug.Trace

import Types
import Obj
import Util
import Lookup
import TypeError

-- | Used for calling back to the 'eval' function in Eval.hs
type DynamicEvaluator = Env -> XObj -> StateT Context IO (Either EvalError XObj)

-- | Keep expanding the form until it doesn't change anymore.
-- | Note: comparing environments is tricky! Make sure they *can* be equal, otherwise this won't work at all!
expandAll :: DynamicEvaluator -> Env -> XObj -> StateT Context IO (Either EvalError XObj)
expandAll eval env root =
  do fullyExpanded <- expandAllInternal root
     return (fmap setNewIdentifiers fullyExpanded)
  where expandAllInternal xobj =
          do expansionResult <- expand eval env xobj
             case expansionResult of
               Right expanded -> if expanded == xobj
                                 then return (Right expanded)
                                 else expandAll eval env expanded
               err -> return err

-- | Macro expansion of a single form
expand :: DynamicEvaluator -> Env -> XObj -> StateT Context IO (Either EvalError XObj)
expand eval env xobj =
  case obj xobj of
  --case obj (trace ("Expand: " ++ pretty xobj) xobj) of
    Lst _ -> expandList xobj
    Arr _ -> expandArray xobj
    Sym _ _ -> expandSymbol xobj
    _     -> return (Right xobj)

  where
    expandList :: XObj -> StateT Context IO (Either EvalError XObj)
    expandList (XObj (Lst xobjs) i t) = do
      ctx <- get
      let fppl = projectFilePathPrintLength (contextProj ctx)
      case xobjs of
        [] -> return (Right xobj)
        XObj (External _) _ _ : _ -> return (Right xobj)
        XObj (Instantiate _) _ _ : _ -> return (Right xobj)
        XObj (Deftemplate _) _ _ : _ -> return (Right xobj)
        XObj (Defalias _) _ _ : _ -> return (Right xobj)
        [defnExpr@(XObj Defn _ _), name, args, body] ->
          do expandedBody <- expand eval env body
             return $ do okBody <- expandedBody
                         Right (XObj (Lst [defnExpr, name, args, okBody]) i t)
        [defExpr@(XObj Def _ _), name, expr] ->
          do expandedExpr <- expand eval env expr
             return $ do okExpr <- expandedExpr
                         Right (XObj (Lst [defExpr, name, okExpr]) i t)
        [theExpr@(XObj The _ _), typeXObj, value] ->
          do expandedValue <- expand eval env value
             return $ do okValue <- expandedValue
                         Right (XObj (Lst [theExpr, typeXObj, okValue]) i t)
        [ifExpr@(XObj If _ _), condition, trueBranch, falseBranch] ->
          do expandedCondition <- expand eval env condition
             expandedTrueBranch <- expand eval env trueBranch
             expandedFalseBranch <- expand eval env falseBranch
             return $ do okCondition <- expandedCondition
                         okTrueBranch <- expandedTrueBranch
                         okFalseBranch <- expandedFalseBranch
                         -- This is a HACK so that each branch of the if statement
                         -- has a "safe place" (= a do-expression with just one element)
                         -- where it can store info about its deleters. Without this,
                         -- An if statement with let-expression inside will duplicate
                         -- the calls to Delete when emitting code.
                         let wrappedTrue =
                               case okTrueBranch of
                                 XObj (Lst (XObj Do _ _ : _)) _ _ -> okTrueBranch -- Has a do-expression already
                                 _ -> XObj (Lst [XObj Do Nothing Nothing, okTrueBranch]) (info okTrueBranch) Nothing
                             wrappedFalse =
                               case okFalseBranch of
                                 XObj (Lst (XObj Do _ _ : _)) _ _ -> okFalseBranch -- Has a do-expression already
                                 _ -> XObj (Lst [XObj Do Nothing Nothing, okFalseBranch]) (info okFalseBranch) Nothing

                         Right (XObj (Lst [ifExpr, okCondition, wrappedTrue, wrappedFalse]) i t)
        [letExpr@(XObj Let _ _), XObj (Arr bindings) bindi bindt, body] ->
          if even (length bindings)
          then do bind <- mapM (\(n, x) -> do x' <- expand eval env x
                                              return $ do okX <- x'
                                                          (Right [n, okX]))
                               (pairwise bindings)
                  expandedBody <- expand eval env body
                  return $ do okBindings <- sequence bind
                              okBody <- expandedBody
                              Right (XObj (Lst [letExpr, XObj (Arr (concat okBindings)) bindi bindt, okBody]) i t)
          else return (makeEvalError ctx Nothing (
            "I ecountered an odd number of forms inside a `let` (`" ++
            pretty xobj ++ "`)")
            (info xobj))

        matchExpr@(XObj Match _ _) : expr : rest ->
          if null rest
            then return (makeEvalError ctx Nothing "I encountered a `match` without forms" (info xobj))
            else if even (length rest)
                 then do expandedExpr <- expand eval env expr
                         expandedPairs <- mapM (\(l,r) -> do expandedR <- expand eval env r
                                                             return [Right l, expandedR])
                                               (pairwise rest)
                         let expandedRest = sequence (concat expandedPairs)
                         return $ do okExpandedExpr <- expandedExpr
                                     okExpandedRest <- expandedRest
                                     return (XObj (Lst (matchExpr : okExpandedExpr : okExpandedRest)) i t)
                 else return (makeEvalError ctx Nothing
                    "I encountered an odd number of forms inside a `match`"
                    (info xobj))

        doExpr@(XObj Do _ _) : expressions ->
          do expandedExpressions <- mapM (expand eval env) expressions
             return $ do okExpressions <- sequence expandedExpressions
                         Right (XObj (Lst (doExpr : okExpressions)) i t)
        [withExpr@(XObj With _ _), pathExpr@(XObj (Sym path _) _ _), expression] ->
          do expandedExpression <- expand eval env expression
             return $ do okExpression <- expandedExpression
                         Right (XObj (Lst [withExpr, pathExpr , okExpression]) i t) -- Replace the with-expression with just the expression!
        [withExpr@(XObj With _ _), _, _] ->
          return (makeEvalError ctx Nothing ("I encountered the value `" ++ pretty xobj ++
            "` inside a `with` at " ++ prettyInfoFromXObj xobj ++
            ".\n\n`with` accepts only symbols.")
            Nothing)
        (XObj With _ _) : _ ->
          return (makeEvalError ctx Nothing (
            "I encountered multiple forms inside a `with` at " ++
            prettyInfoFromXObj xobj ++
            ".\n\n`with` accepts only one expression, except at the top level.")
            Nothing)
        XObj Mod{} _ _ : _ ->
          return (makeEvalError ctx Nothing ("I can’t evaluate the module `" ++
                                             pretty xobj ++ "`")
                                            (info xobj))
        f:args -> do expandedF <- expand eval env f
                     expandedArgs <- fmap sequence (mapM (expand eval env) args)
                     case expandedF of
                       Right (XObj (Lst [XObj Dynamic _ _, _, XObj (Arr _) _ _, _]) _ _) ->
                         --trace ("Found dynamic: " ++ pretty xobj)
                         eval env xobj
                       Right (XObj (Lst [XObj Macro _ _, _, XObj (Arr _) _ _, _]) _ _) ->
                         --trace ("Found macro: " ++ pretty xobj ++ " at " ++ prettyInfoFromXObj xobj)
                         eval env xobj
                       Right (XObj (Lst [XObj (Command callback) _ _, _]) _ _) ->
                         (getCommand callback) args
                       Right _ ->
                         return $ do okF <- expandedF
                                     okArgs <- expandedArgs
                                     Right (XObj (Lst (okF : okArgs)) i t)
                       Left err -> return (Left err)
    expandList _ = error "Can't expand non-list in expandList."

    expandArray :: XObj -> StateT Context IO (Either EvalError XObj)
    expandArray (XObj (Arr xobjs) i t) =
      do evaledXObjs <- fmap sequence (mapM (expand eval env) xobjs)
         return $ do okXObjs <- evaledXObjs
                     Right (XObj (Arr okXObjs) i t)
    expandArray _ = error "Can't expand non-array in expandArray."

    expandSymbol :: XObj -> StateT Context IO (Either a XObj)
    expandSymbol (XObj (Sym path _) _ _) =
      case lookupInEnv path env of
        Just (_, Binder _ (XObj (Lst (XObj (External _) _ _ : _)) _ _)) -> return (Right xobj)
        Just (_, Binder _ (XObj (Lst (XObj (Instantiate _) _ _ : _)) _ _)) -> return (Right xobj)
        Just (_, Binder _ (XObj (Lst (XObj (Deftemplate _) _ _ : _)) _ _)) -> return (Right xobj)
        Just (_, Binder _ (XObj (Lst (XObj Defn _ _ : _)) _ _)) -> return (Right xobj)
        Just (_, Binder _ (XObj (Lst (XObj Def _ _ : _)) _ _)) -> return (Right xobj)
        Just (_, Binder _ (XObj (Lst (XObj (Defalias _) _ _ : _)) _ _)) -> return (Right xobj)
        Just (_, Binder _ found) -> return (Right found) -- use the found value
        Nothing -> return (Right xobj) -- symbols that are not found are left as-is
    expandSymbol _ = error "Can't expand non-symbol in expandSymbol."

-- | Replace all the infoIdentifier:s on all nested XObj:s
setNewIdentifiers :: XObj -> XObj
setNewIdentifiers root = let final = evalState (visit root) 0
                         in final
                           --trace ("ROOT: " ++ prettyTyped root ++ "FINAL: " ++ prettyTyped final) final
  where
    visit :: XObj -> State Int XObj
    visit xobj =
      case obj xobj of
        (Lst _) -> visitList xobj
        (Arr _) -> visitArray xobj
        _ -> bumpAndSet xobj

    visitList :: XObj -> State Int XObj
    visitList (XObj (Lst xobjs) i t) =
      do visited <- mapM visit xobjs
         let xobj' = XObj (Lst visited) i t
         bumpAndSet xobj'
    visitList _ = error "The function 'visitList' only accepts XObjs with lists in them."

    visitArray :: XObj -> State Int XObj
    visitArray (XObj (Arr xobjs) i t) =
      do visited <- mapM visit xobjs
         let xobj' = XObj (Arr visited) i t
         bumpAndSet xobj'
    visitArray _ = error "The function 'visitArray' only accepts XObjs with arrays in them."

    bumpAndSet :: XObj -> State Int XObj
    bumpAndSet xobj =
      do counter <- get
         put (counter + 1)
         case info xobj of
           Just i -> return (xobj { info = Just (i { infoIdentifier = counter })})
           Nothing -> return xobj

-- | Replaces the file, line and column info on an XObj an all its children.
replaceSourceInfo :: FilePath -> Int -> Int -> XObj -> XObj
replaceSourceInfo newFile newLine newColumn root = visit root
  where
    visit :: XObj -> XObj
    visit xobj =
      case obj xobj of
        (Lst _) -> visitList xobj
        (Arr _) -> visitArray xobj
        _ -> setNewInfo xobj

    visitList :: XObj -> XObj
    visitList (XObj (Lst xobjs) i t) =
      setNewInfo (XObj (Lst (map visit xobjs)) i t)
    visitList _ =
      error "The function 'visitList' only accepts XObjs with lists in them."

    visitArray :: XObj -> XObj
    visitArray (XObj (Arr xobjs) i t) =
      setNewInfo (XObj (Arr (map visit xobjs)) i t)
    visitArray _ = error "The function 'visitArray' only accepts XObjs with arrays in them."

    setNewInfo :: XObj -> XObj
    setNewInfo xobj =
      case info xobj of
        Just i -> (xobj { info = Just (i { infoFile = newFile
                                         , infoLine = newLine
                                         , infoColumn = newColumn
                                         })})
        Nothing -> xobj

replaceSourceInfoOnXObj :: Maybe Info -> XObj -> XObj
replaceSourceInfoOnXObj newInfo xobj =
  case newInfo of
    Just i  -> replaceSourceInfo (infoFile i) (infoLine i) (infoColumn i) xobj
    Nothing -> xobj
