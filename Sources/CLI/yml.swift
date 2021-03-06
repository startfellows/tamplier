//
//  Created by Anton Spivak.
//  

import Foundation
import Mustache

extension API {
    
    struct YML: Codable, MustacheBoxable {
        
        struct Info: Codable, MustacheBoxable {
            
            let title: String
            let description: String
            let version: String
        }
        
        struct Server: Codable, MustacheBoxable {
            
            var name: String?
            let url: String
        }
        
        struct Schema: Codable, MustacheBoxable {
            
            enum SchemaType: String, Codable, MustacheBoxable {
                
                case object
                case string
            }
            
            enum CodingKeys: String, CodingKey {
                
                case allOf
                case ref = "$ref"
                case type
                case `enum`
                case description
                case required
                case properties
            }
            
            private(set) var allOf: [Property]?
            private(set) var ref: String?
            private(set) var type: SchemaType?
            private(set) var `enum`: [String]?
            private(set) var description: String?
            private(set) var required: [String]?
            private(set) var properties: [String : Property]?
            
            static func combine(_ schemas: [Schema]) -> Schema {
                var schema = Schema()
                schema.type = .object
                schema.required = schemas.compactMap({ $0.required }).reduce([String](), +)
                schema.properties = schemas.compactMap({ $0.properties }).reduce([String : Property](), { $0._merge(dict: $1) })
                return schema
            }
        }
        
        struct Components: Codable, MustacheBoxable {
            
            let schemas: [String : Schema]
        }
        
        struct Path: Codable, MustacheBoxable {
            
            let summary: String
            let parameters: [PathProperty]?
            let requestBody: PathRequest?
            let responses: [String : PathResponse]
        }
        
        let info: Info
        let servers: [Server]
        let components: Components
        let paths: [String : [String : Path]]
    }
}

extension API.YML.Path {
    
    struct PathRequest: Codable, MustacheBoxable {
     
        let content: [String : PathRequestContent]?
    }
    
    struct PathRequestContent: Codable, MustacheBoxable {
     
        let schema: API.YML.Property
    }
    
    struct PathResponse: Codable, MustacheBoxable {
     
        let description: String
        let content: [String : PathResponseContent]?
    }
    
    struct PathResponseContent: Codable, MustacheBoxable {
     
        let schema: API.YML.Property
    }
    
    struct PathSchema: Codable, MustacheBoxable {
        
        let type: String
    }
    
    struct PathProperty: Codable, MustacheBoxable {
        
        let `in`: String
        let name: String
        let schema: API.YML.Property
        let required: Bool?
    }
    
    static func escapedName(withPathSource path: String) -> String {
        let components = path.components(separatedBy: "/").map({ subpath -> String in
            if subpath.hasPrefix("{") && subpath.hasSuffix("}") {
                let name = subpath.dropFirst(1).dropLast(1).components(separatedBy: "_").map({ $0.uppercaseFirstLetter() }).map({ $0 == "Id" ? "ID" : $0 }).joined()
                return "By\(name)"
            } else {
                return subpath.uppercaseFirstLetter()
            }
        })
        return components.joined()
    }
}

extension API.YML {
    
    struct Property: Codable, MustacheBoxable {
        
        enum CodingKeys: String, CodingKey {
            
            case type = "type"
            case ref = "$ref"
            case description
            case items
            case format
            case `enum`
        }
        
        let type: String?
        let format: String?
        let ref: String?
        let description: String?
        let items: Subproperty?
        let `enum`: [String]?
    }
    
    struct Subproperty: Codable, MustacheBoxable {
        
        enum CodingKeys: String, CodingKey {
            
            case type = "type"
            case ref = "$ref"
            case format
        }
        
        let type: String?
        let format: String?
        let ref: String?
    }
}

extension API.YML.Property {
    
    struct SchemaPropertyEnum {
        
        let name: String
        let cases: [(String, String?)]
    }
    
    func expandedTypeWithSchema(schemaName: String? = nil, propertyName: String? = nil) -> (String?, SchemaPropertyEnum?) {
        if let type = self.type {
            switch type {
            case "string":
                if format == "binary" {
                    return ("Data", nil)
                } else if let cases = self.enum, let schemaName = schemaName, let propertyName = propertyName {
                    let name = schemaName.uppercaseFirstLetter() + propertyName.uppercaseFirstLetter()
                    let descriptions = parseEnumDescription(description)
                    let _enum = SchemaPropertyEnum(
                        name: name,
                        cases: cases.mapIndex({ (ecase, index) in
                            return (ecase, descriptions.1[ecase])
                        })
                    )
                    return (name, _enum)
                } else {
                    return ("String", nil)
                }
            case "integer":
                switch (format ?? "") {
                case "int64": return ("Int64", nil)
                case "int32": return ("Int32", nil)
                default: return ("Int", nil)
                }
            case "boolean":
                return ("Bool", nil)
            case "number":
                if self.enum != nil {
                    print("Enum's for type `number` not supported")
                    return (nil, nil)
                }
                switch (format ?? "") {
                case "Double": return ("Double", nil)
                case "Float": return ("Float", nil)
                default: return ("Double", nil)
                }
            case "array":
                if self.enum != nil {
                    print("Enum's for type `array` not supported")
                    return (nil, nil)
                }
                guard let items = items, let subtype = items.expandedType()
                else {
                    return (nil, nil)
                }
                return ("[\(subtype)]", nil)
            default:
                return (nil, nil)
            }
        } else if let _ref = self.ref {
            return (_ref.components(separatedBy: "/").last ?? "", nil)
        } else {
            return (nil, nil)
        }
    }
    
    private func parseEnumDescription(_ string: String?) -> (String?, [String : String]) {
        guard let string = string
        else {
            return (nil, [:])
        }
        
        var separated = string.components(separatedBy: "\n")
        var response: (String?, [String : String]) = (nil, [:])
        
        if let common = separated.first, common.hasSuffix("|") {
            response.0 = common.replacingOccurrences(of: "|", with: "")
            separated = Array(separated.dropFirst())
        }
        
        separated.forEach({ element in
            let separated = element.components(separatedBy: " - ")
            if separated.count == 2 {
                let name = String(separated[0].dropFirst().dropFirst())
                response.1[name] = separated[1]
            }
        })
        
        return response
    }
}

extension API.YML.Subproperty {
    
    fileprivate func expandedType() -> String? {
        if let type = self.type {
            switch type {
            case "string":
                if format == "binary" {
                    return "Data"
                } else {
                    return "String"
                }
            case "integer":
                switch (format ?? "") {
                case "int64": return "Int64"
                case "int32": return "Int32"
                default: return "Int"
                }
            case "boolean":
                return "Bool"
            case "number":
                switch (format ?? "") {
                case "Double": return "Double"
                case "Float": return "Float"
                default: return "Double"
                }
            case "array": return nil
            default: return nil
            }
        } else if let _ref = self.ref {
            if let last = _ref.components(separatedBy: "/").last {
                return "API.\(last)"
            } else {
                return nil
            }
        } else {
            return nil
        }
    }
}

extension MustacheBoxable where Self: Encodable {
    
    var mustacheBox: MustacheBox {
        guard let data = try? JSONEncoder().encode(self),
              let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        else {
            return Box(nil)
        }
        return Box(json)
    }
}

extension Dictionary {
    
    func _merge(dict: [Key : Value]) -> [Key : Value] {
        var new: [Key : Value] = self
        for (k, v) in dict {
            new[k] = v
        }
        return new
    }
}
