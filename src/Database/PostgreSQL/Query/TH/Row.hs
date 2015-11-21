module Database.PostgreSQL.Query.TH.Row where

import Prelude

import Database.PostgreSQL.Query.TH.Enum

import Control.Applicative
import Control.Monad
import Data.Default
import Data.FileEmbed ( embedFile )
import Data.String
import Database.PostgreSQL.Query.Entity ( Entity(..) )
import Database.PostgreSQL.Query.TH.Common
import Database.PostgreSQL.Query.Types ( FN(..) )
import Database.PostgreSQL.Simple.FromRow ( FromRow(..), field )
import Database.PostgreSQL.Simple.ToRow ( ToRow(..) )
import Database.PostgreSQL.Simple.Types ( Query(..) )
import Language.Haskell.TH
import Language.Haskell.TH.Syntax


{-| Derive 'FromRow' instance. i.e. you have type like that

@
data Entity = Entity
              { eField :: Text
              , eField2 :: Int
              , efield3 :: Bool }
@

then 'deriveFromRow' will generate this instance:
instance FromRow Entity where

@
instance FromRow Entity where
    fromRow = Entity
              \<$> field
              \<*> field
              \<*> field
@

Datatype must have just one constructor with arbitrary count of fields
-}

deriveFromRow :: Name -> Q [Dec]
deriveFromRow t = do
    TyConI (DataD _ _ _ [con] _) <- reify t
    cname <- cName con
    cargs <- cArgs con
    [d|instance FromRow $(return $ ConT t) where
           fromRow = $(fieldsQ cname cargs)|]
  where
    fieldsQ cname cargs = do
        fld <- [| field |]
        fmp <- [| (<$>) |]
        fap <- [| (<*>) |]
        return $ UInfixE (ConE cname) fmp (fapChain cargs fld fap)

    fapChain 0 _ _ = error "there must be at least 1 field in constructor"
    fapChain 1 fld _ = fld
    fapChain n fld fap = UInfixE fld fap (fapChain (n-1) fld fap)

{-| derives 'ToRow' instance for datatype like

@
data Entity = Entity
              { eField :: Text
              , eField2 :: Int
              , efield3 :: Bool }
@

it will derive instance like that:

@
instance ToRow Entity where
     toRow (Entity e1 e2 e3) =
         [ toField e1
         , toField e2
         , toField e3 ]
@
-}

deriveToRow :: Name -> Q [Dec]
deriveToRow t = do
    TyConI (DataD _ _ _ [con] _) <- reify t
    cname <- cName con
    cargs <- cArgs con
    cvars <- sequence
             $ replicate cargs
             $ newName "a"
    [d|instance ToRow $(return $ ConT t) where
           toRow $(return $ ConP cname $ map VarP cvars) = $(toFields cvars)|]
  where
    toFields v = do
        tof <- lookupVNameErr "toField"
        return $ ListE $ map (\e -> AppE (VarE tof) (VarE e)) v