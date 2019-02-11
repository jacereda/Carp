module GenerateConstraints (genConstraints) where

import Data.List (foldl', sort, zipWith4)
import Control.Arrow
import Control.Monad.State
import Data.Maybe (mapMaybe)
import Debug.Trace (trace)

import Types
import Obj
import Constraints
import Util
import TypeError
import Lookup

-- | Will create a list of type constraints for a form.
genConstraints :: TypeEnv -> XObj -> Either TypeError [Constraint]
genConstraints typeEnv root = fmap sort (gen root)
  where gen xobj =
          case obj xobj of
            Lst lst -> case lst of
                           -- Defn
                           [XObj Defn _ _, _, XObj (Arr args) _ _, body] ->
                             do insideBodyConstraints <- gen body
                                xobjType <- toEither (ty xobj) (DefnMissingType xobj)
                                bodyType <- toEither (ty body) (ExpressionMissingType xobj)
                                let (FuncTy argTys retTy) = xobjType
                                    bodyConstr = Constraint retTy bodyType xobj body OrdDefnBody
                                    argConstrs = zipWith3 (\a b aObj -> Constraint a b aObj xobj OrdArg) (map forceTy args) argTys args
                                return (bodyConstr : argConstrs ++ insideBodyConstraints)

                           -- Fn
                           -- TODO: Too much duplication from Defn...
                           [XObj (Fn _ _) _ _, XObj (Arr args) _ _, body] ->
                             do insideBodyConstraints <- gen body
                                xobjType <- toEither (ty xobj) (DefnMissingType xobj)
                                bodyType <- toEither (ty body) (ExpressionMissingType xobj)
                                let (FuncTy argTys retTy) = xobjType
                                    bodyConstr = Constraint retTy bodyType xobj body OrdDefnBody
                                    argConstrs = zipWith3 (\a b aObj -> Constraint a b aObj xobj OrdArg) (map forceTy args) argTys args
                                return (bodyConstr : argConstrs ++ insideBodyConstraints)

                           -- Def
                           [XObj Def _ _, _, expr] ->
                             do insideExprConstraints <- gen expr
                                xobjType <- toEither (ty xobj) (DefMissingType xobj)
                                exprType <- toEither (ty expr) (ExpressionMissingType xobj)
                                let defConstraint = Constraint xobjType exprType xobj expr OrdDefExpr
                                return (defConstraint : insideExprConstraints)

                           -- Let
                           [XObj Let _ _, XObj (Arr bindings) _ _, body] ->
                             do insideBodyConstraints <- gen body
                                insideBindingsConstraints <- fmap join (mapM gen bindings)
                                bodyType <- toEither (ty body) (ExpressionMissingType body)
                                let Just xobjTy = ty xobj
                                    wholeStatementConstraint = Constraint bodyType xobjTy body xobj OrdLetBody
                                    bindingsConstraints = zipWith (\(symTy, exprTy) (symObj, exprObj) ->
                                                                     Constraint symTy exprTy symObj exprObj OrdLetBind)
                                                                  (map (forceTy *** forceTy) (pairwise bindings))
                                                                  (pairwise bindings)
                                return (wholeStatementConstraint : insideBodyConstraints ++
                                        bindingsConstraints ++ insideBindingsConstraints)

                           -- If
                           [XObj If _ _, expr, ifTrue, ifFalse] ->
                             do insideConditionConstraints <- gen expr
                                insideTrueConstraints <- gen ifTrue
                                insideFalseConstraints <- gen ifFalse
                                exprType <- toEither (ty expr) (ExpressionMissingType expr)
                                trueType <- toEither (ty ifTrue) (ExpressionMissingType ifTrue)
                                falseType <- toEither (ty ifFalse) (ExpressionMissingType ifFalse)
                                let expected = XObj (Sym (SymPath [] "Condition in if-value") Symbol) (info expr) (Just BoolTy)
                                    conditionConstraint = Constraint exprType BoolTy expr expected OrdIfCondition
                                    sameReturnConstraint = Constraint trueType falseType ifTrue ifFalse OrdIfReturn
                                    Just t = ty xobj
                                    wholeStatementConstraint = Constraint trueType t ifTrue xobj OrdIfWhole
                                return (conditionConstraint : sameReturnConstraint :
                                        wholeStatementConstraint : insideConditionConstraints ++
                                        insideTrueConstraints ++ insideFalseConstraints)

                           -- Match
                           XObj Match _ _ : expr : cases ->
                             do insideExprConstraints <- gen expr
                                insideCasesConstraints <- fmap join (mapM gen (map snd (pairwise cases)))
                                exprType <- toEither (ty expr) (ExpressionMissingType expr)
                                xobjType <- toEither (ty xobj) (DefMissingType xobj)

                                let -- Each case should have the same return type as the whole match form:
                                  mkConstr x@(XObj _ _ (Just t)) = Just (Constraint t xobjType x xobj OrdArg) -- | TODO: Ord
                                  mkConstr _ = Nothing
                                  casesBodyConstraints = mapMaybe (\(tag, caseExpr) -> mkConstr caseExpr) (pairwise cases)

                                  -- Constraints for the variables in the left side of each matching case,
                                  -- like the 'r'/'g'/'b' in (match col (RGB r g b) ...) being constrained to Int.
                                  casesLhsConstraints = concatMap (genLhsConstraintsInCase typeEnv exprType) (map fst (pairwise cases))

                                  exprConstraint =
                                    -- | TODO: Only guess if there isn't already a type set on the expression!
                                    case guessExprType typeEnv cases of
                                      Just guessedExprTy ->
                                        let expected = XObj (Sym (SymPath [] "Expression in match-statement") Symbol)
                                                       (info expr) (Just guessedExprTy)
                                        in  [Constraint exprType guessedExprTy expr expected OrdIfCondition] -- | TODO: Ord
                                      Nothing ->
                                        []

                                return (exprConstraint ++
                                        insideExprConstraints ++
                                        insideCasesConstraints ++
                                        casesBodyConstraints ++
                                        casesLhsConstraints)

                           -- While
                           [XObj While _ _, expr, body] ->
                             do insideConditionConstraints <- gen expr
                                insideBodyConstraints <- gen body
                                exprType <- toEither (ty expr) (ExpressionMissingType expr)
                                bodyType <- toEither (ty body) (ExpressionMissingType body)
                                let expectedCond = XObj (Sym (SymPath [] "Condition in while-expression") Symbol) (info expr) (Just BoolTy)
                                    expectedBody = XObj (Sym (SymPath [] "Body in while-expression") Symbol) (info xobj) (Just UnitTy)
                                    conditionConstraint = Constraint exprType BoolTy expr expectedCond OrdWhileCondition
                                    wholeStatementConstraint = Constraint bodyType UnitTy body expectedBody OrdWhileBody
                                return (conditionConstraint : wholeStatementConstraint :
                                        insideConditionConstraints ++ insideBodyConstraints)

                           -- Do
                           XObj Do _ _ : expressions ->
                             case expressions of
                               [] -> Left (NoStatementsInDo xobj)
                               _ -> let lastExpr = last expressions
                                    in do insideExpressionsConstraints <- fmap join (mapM gen expressions)
                                          xobjType <- toEither (ty xobj) (DefMissingType xobj)
                                          lastExprType <- toEither (ty lastExpr) (ExpressionMissingType xobj)
                                          let retConstraint = Constraint xobjType lastExprType xobj lastExpr OrdDoReturn
                                              must = XObj (Sym (SymPath [] "Statement in do-expression") Symbol) (info xobj) (Just UnitTy)
                                              mkConstr x@(XObj _ _ (Just t)) = Just (Constraint t UnitTy x must OrdDoStatement)
                                              mkConstr _ = Nothing
                                              expressionsShouldReturnUnit = mapMaybe mkConstr (init expressions)
                                          return (retConstraint : insideExpressionsConstraints ++ expressionsShouldReturnUnit)

                           -- Address
                           [XObj Address _ _, value] ->
                             gen value

                           -- Set!
                           [XObj SetBang _ _, variable, value] ->
                             do insideValueConstraints <- gen value
                                insideVariableConstraints <- gen variable
                                variableType <- toEither (ty variable) (ExpressionMissingType variable)
                                valueType <- toEither (ty value) (ExpressionMissingType value)
                                let sameTypeConstraint = Constraint variableType valueType variable value OrdSetBang
                                return (sameTypeConstraint : insideValueConstraints ++ insideVariableConstraints)

                           -- The
                           [XObj The _ _, _, value] ->
                             do insideValueConstraints <- gen value
                                xobjType <- toEither (ty xobj) (DefMissingType xobj)
                                valueType <- toEither (ty value) (DefMissingType value)
                                let theTheConstraint = Constraint xobjType valueType xobj value OrdThe
                                return (theTheConstraint : insideValueConstraints)

                           -- Ref
                           [XObj Ref _ _, value] ->
                             gen value

                           -- Deref
                           [XObj Deref _ _, value] ->
                             do insideValueConstraints <- gen value
                                xobjType <- toEither (ty xobj) (ExpressionMissingType xobj)
                                valueType <- toEither (ty value) (ExpressionMissingType value)
                                let theTheConstraint = Constraint (RefTy xobjType) valueType xobj value OrdDeref
                                return (theTheConstraint : insideValueConstraints)

                           -- Break
                           [XObj Break _ _] ->
                             return []

                           -- Function application
                           func : args ->
                             do funcConstraints <- gen func
                                insideArgsConstraints <- fmap join (mapM gen args)
                                funcTy <- toEither (ty func) (ExpressionMissingType func)
                                case funcTy of
                                  (FuncTy argTys retTy) ->
                                    if length args /= length argTys then
                                      Left (WrongArgCount func)
                                    else
                                      let expected t n =
                                            XObj (Sym (SymPath [] ("Expected " ++ enumerate n ++ " argument to '" ++ getName func ++ "'")) Symbol)
                                            (info func) (Just t)
                                          argConstraints = zipWith4 (\a t aObj n -> Constraint a t aObj (expected t n) OrdFuncAppArg)
                                                                    (map forceTy args)
                                                                    argTys
                                                                    args
                                                                    [0..]
                                          Just xobjTy = ty xobj
                                          retConstraint = Constraint xobjTy retTy xobj func OrdFuncAppRet
                                      in  return (retConstraint : funcConstraints ++ argConstraints ++ insideArgsConstraints)
                                  funcVarTy@(VarTy _) ->
                                    let fabricatedFunctionType = FuncTy (map forceTy args) (forceTy xobj)
                                        expected = XObj (Sym (SymPath [] ("Calling '" ++ getName func ++ "'")) Symbol) (info func) Nothing
                                        wholeTypeConstraint = Constraint funcVarTy fabricatedFunctionType func expected OrdFuncAppVarTy
                                    in  return (wholeTypeConstraint : funcConstraints ++ insideArgsConstraints)
                                  _ -> Left (NotAFunction func)

                           -- Empty list
                           [] -> Right []

            (Arr arr) ->
              case arr of
                [] -> Right []
                x:xs -> do insideExprConstraints <- fmap join (mapM gen arr)
                           let Just headTy = ty x
                               Just (StructTy "Array" [t]) = ty xobj
                               betweenExprConstraints = map (\o -> Constraint headTy (forceTy o) x o OrdArrBetween) xs
                               headConstraint = Constraint headTy t x xobj OrdArrHead
                           return (headConstraint : insideExprConstraints ++ betweenExprConstraints)

            _ -> Right []



-- | Try to guess the type of X in (match X ...) based on the matching clauses
-- | TODO: Look through all cases for a guess and make sure they all converge on a single sumtype.
guessExprType :: TypeEnv -> [XObj] -> Maybe Ty
guessExprType typeEnv [] =
  error "No case expressions to base guess on."
guessExprType typeEnv (firstCaseXObj : caseXObjs) =
  case firstCaseXObj of
    (XObj (Lst (XObj (Sym (SymPath pathStrings tagName) _) _ _ : _)) _ _) ->
      case pathStrings of
        [] -> Nothing
        _ -> tryFindSumtypeTy typeEnv (SymPath (init pathStrings) (last pathStrings))

tryFindSumtypeTy :: TypeEnv -> SymPath -> Maybe Ty
tryFindSumtypeTy typeEnv sumtypePath =
  case lookupInEnv sumtypePath (getTypeEnv typeEnv) of
    Just (_, foundBinder@(Binder meta (XObj (Lst (XObj (DefSumtype sumTy) _ _ : XObj (Sym _ _) _ _ : _)) _ _))) ->
      Just sumTy
    Just somethingElse ->
      error ("Found non-sumtype: " ++ show somethingElse)
    Nothing ->
      Nothing

-- | Find the sumtype at a specific path and extract the case matching the final part of the path, i.e. the 'Just' in "Maybe.Just"
getCaseFromPath :: TypeEnv -> SymPath -> Maybe SumtypeCase
getCaseFromPath typeEnv (SymPath pathStrings caseName) =
  case pathStrings of
    [] ->
      Nothing
    [sumtypeName] ->
      tryFindCase (SymPath [] sumtypeName)
    pathAndName ->
      Nothing -- | TODO: Can't handle nested types yet, but when we do it has to be handled here.
  where tryFindCase fullPath =
          case lookupInEnv fullPath (getTypeEnv typeEnv) of
            Just (_, Binder _ (XObj (Lst (XObj (DefSumtype _) _ _ : _ : rest)) _ _)) ->
              let cases = toCases rest
              in  getCase cases caseName
            Just (_, Binder _ x) ->
              error ("A non-sumtype named '" ++ show fullPath ++ "' was found in the type environment: " ++ show x)
            Nothing ->
              error ("Failed to find a sumtype named '" ++ show fullPath ++ "' in the type environment.")

-- | Generate the constraints for the left hand side of a 'match' case (e.g. "(Just x)" or "(Maybe.Just x)")
-- | If we don't know which sumtype to use, return no constraints.
-- | TODO: The logic in this functions is kind of a mess, clean it up!
genLhsConstraintsInCase :: TypeEnv -> Ty -> XObj -> [Constraint]
genLhsConstraintsInCase typeEnv exprTy (XObj (Lst ((XObj (Sym symPath _) _ _) : xs)) _ _) =
  let fullPath =
        case symPath of
          SymPath [] name ->
            case exprTy of
              StructTy structName _ -> Just (SymPath [structName] name)
              _ -> Nothing
          SymPath (x:xs) name ->
            Just symPath -- Looks like it's a qualified path, so don't use the known type of the expression
  in  case fullPath of
        Just p ->
          genLhsConstraintsInCaseInternal typeEnv p xs
        Nothing ->
          []

genLhsConstraintsInCaseInternal :: TypeEnv -> SymPath -> [XObj] -> [Constraint]
genLhsConstraintsInCaseInternal typeEnv fullCasePath xs =
  case getCaseFromPath typeEnv fullCasePath of
    Nothing ->
      error ("Couldn't find case in type env: " ++ show fullCasePath)
    Just foundCase ->
      zipWith visitMatchElement xs (caseTys foundCase)
      where visitMatchElement :: XObj -> Ty -> Constraint
            visitMatchElement variable@(XObj (Sym path _) variableInfo variableTy) caseTy =
              let expected = XObj (Sym (SymPath [] "Variable in 'match' case") Symbol) variableInfo (Just caseTy)
                  Just variableTy' = variableTy
              in  Constraint variableTy' caseTy variable expected OrdIfCondition -- | TODO: Ord
            visitMatchTagElement x =
              error ("No matching case in 'visitMatchElement': " ++ show x)
