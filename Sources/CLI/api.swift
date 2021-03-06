//
//  Created by Anton Spivak.
//  

import Foundation
import Rainbow
import ArgumentParser
import Yams 
import Mustache

struct API: ParsableCommand {
    
    struct Configuration: Decodable {
        
        let yml: String
        let output: String
    }
    
    static var configuration = CommandConfiguration(
        commandName: "api",
        abstract: "Generates source files for Swagger backend which depends on Bootstrap API package."
    )
    
    mutating func run() throws {
        let fileManager = FileManager.default
        let cwd = fileManager.currentDirectoryPath
        
        let configurationFilePath = cwd.appending("/Tamfile").standardizingPath()
        let configurationFilePathURL = URL(fileURLWithPath: configurationFilePath)
        guard fileManager.fileExists(atPath: configurationFilePath)
        else {
            throw RuntimeError.message("Can't locate file 'tamplier.json' file in current directory \(cwd)")
        }
        
        let configurationFileData = try Data(contentsOf: configurationFilePathURL)
        let configuration = try JSONDecoder().decode(Configuration.self, from: configurationFileData)
        
        let path = configuration.yml
        let output = configuration.output
        
        let contents = try path.contents()
        guard let dictionary = try load(yaml: contents)
        else {
            throw RuntimeError.message("Can't parse yml at path \(path).")
        }
        
        let gitRepoPath = "git@github.com:sflabsorg/tamplier.git"
        let gitClonePath = "\(cwd)/.tamplier/"
        
        if fileManager.fileExists(atPath: gitClonePath, isDirectory: nil) {
            try fileManager.removeItem(atPath: gitClonePath)
        }
        
        guard shell("git clone \(gitRepoPath) \(gitClonePath)") == 0
        else {
            throw RuntimeError.message("Can't clone \(gitRepoPath), check access rights.")
        }
        
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: .fragmentsAllowed)
        let yml = try JSONDecoder().decode(YML.self, from: data)
        
        let outputPath = "\(output)".standardizingPath()
        #if DEBUG
        #else
        if try !fileManager.isDirectoryEmpty(at: outputPath) {
            print("Directory \(outputPath) not empty.\nContinue? Y/n".red)
            if let y = readLine(), y != "Y" {
                throw RuntimeError.message("Aborted.")
            }
            try fileManager.removeItem(atPath: outputPath)
        }
        #endif
        
        let templatesURL = URL(fileURLWithPath: "\(gitClonePath)/.templates/swagger".standardizingPath())
        let outputURL = URL(fileURLWithPath: outputPath)
        
        try yml.render(templatesURL: templatesURL, outputURL: outputURL)
        
        try fileManager.removeItem(atPath: gitClonePath)
    }
}

extension API.YML {

    func render(templatesURL: URL, outputURL: URL) throws {
        let fileManager = FileManager.default
 
        try? fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: outputURL.appendingPathComponent("Sources"), withIntermediateDirectories: true, attributes: nil)
        
        //
        // Package.swift
        //
        
        try render(
            templatesURL: templatesURL.appendingPathComponent("Package.swift"),
            outputURL: outputURL.appendingPathComponent("Package.swift"),
            data: [
                "name" : "Bootstrap\(info.title.uppercaseFirstLetter())"
            ]
        )
        
        //
        // README.md
        //
        
        try render(
            templatesURL: templatesURL.appendingPathComponent("README.md"),
            outputURL: outputURL.appendingPathComponent("README.md"),
            data: [
                "name" : "\(info.title.uppercaseFirstLetter())"
            ]
        )
        
        //
        // Server.swift
        //
        
        try render(
            templatesURL: templatesURL.appendingPathComponent("Server.swift"),
            outputURL: outputURL.appendingPathComponent("Sources/Server.swift"),
            data: [
                "title" : info.title,
                "description": info.description,
                "servers" : servers.mapIndex({ (_server, index) -> API.YML.Server in
                    var server = _server
                    if server.name == nil {
                        server.name = "server\(index)"
                    }
                    return server
                })
            ]
        )
        
        //
        // Models/
        //
        
        try fileManager.createDirectory(at: outputURL.appendingPathComponent("Sources/Models"), withIntermediateDirectories: true, attributes: nil)
        try components.schemas.map({ name, element -> (String, Schema) in
            if let ref = element.ref {
                let _type = ref.components(separatedBy: "/").last ?? ""
                let schemas = components.schemas.filter({ key, _ in
                    return key == _type
                }).map({ _, schema in
                    return schema
                })
                
                return (name, Schema.combine(schemas))
            } else if let allOf = element.allOf {
                let types = try allOf.compactMap({ property -> String in
                    guard let _ = property.ref
                    else {
                        throw RuntimeError.message("Can't pare `alOf`")
                    }
                    
                    let (_type, _) = property.expandedTypeWithSchema()
                    guard let type = _type
                    else {
                        throw RuntimeError.message("Can't pare `alOf`")
                    }
                    
                    return type
                })
                
                let schemas = components.schemas.filter({ key, _ in
                    return types.contains(key)
                }).map({ _, schema in
                    return schema
                })
                
                return (name, Schema.combine(schemas))
            } else {
                return (name, element)
            }
        }).forEach({ (name, schema) in
            guard let type = schema.type
            else {
                return
            }
            
            switch type {
            case .object:
                var enums: [[AnyHashable : Any]] = []
                var properties = schema.properties?.compactMap({ (key, value) -> [String : Any]? in
                    let (_type, _enum) = value.expandedTypeWithSchema(schemaName: name, propertyName: key)
                    guard var type = _type
                    else {
                        return nil
                    }
                    
                    if !(schema.required ?? []).contains(key) {
                        type += "?"
                    }
                    
                    var data: [String : Any] = [
                        "name" : key,
                        "type" : type
                    ]
                    
                    if let eenum = _enum {
                        enums.append([
                            "name" : eenum.name,
                            "type" : "String",
                            "cases" : eenum.cases.map({ (ccase, description) in
                                return [
                                    "name" : ccase,
                                    "description" : description ?? "Description not provided"
                                ]
                            })
                        ])
                    } else {
                        data["description"] = value.description ?? "Description not provided"
                    }
                    
                    return data
                })
                
                properties?.sort(by: { (l, r) in
                    guard let _l = l["name"] as? String,
                          let _r = r["name"] as? String
                    else {
                        return false
                    }
                    return _l < _r
                })
                
                let data: [AnyHashable : Any] = [
                    "name" : name,
                    "description": schema.description ?? "Description not provided",
                    "properties" : properties ?? [],
                    "init" : properties?.map({ "\($0["name"]!): \($0["type"]!)" }).joined(separator: ", ") ?? "",
                    "enums" : enums
                ]
                
                try render(
                    templatesURL: templatesURL.appendingPathComponent("Object.swift"),
                    outputURL: outputURL.appendingPathComponent("Sources/Models/\(name).swift"),
                    data: data
                )
            case .string:
                guard let cases = schema.enum
                else {
                    throw RuntimeError.message("Schema with type 'string' doesn't contain enum. \(schema)")
                }
                
                let data: [AnyHashable : Any] = [
                    "name" : name,
                    "description": schema.description ?? "Description not provided",
                    "type": "String",
                    "cases": cases.map({ ccase in
                        return [
                            "name" : ccase,
                            "description": "Description not provided"
                        ]
                    })
                ]
                
                try render(
                    templatesURL: templatesURL.appendingPathComponent("Enum.swift"),
                    outputURL: outputURL.appendingPathComponent("Sources/Models/\(name).swift"),
                    data: data
                )
            }
        })
        
        //
        // Queries/
        //
        
        try fileManager.createDirectory(at: outputURL.appendingPathComponent("Sources/Queries"), withIntermediateDirectories: true, attributes: nil)
        try paths.forEach({ (pathSource, pathType) in
            let name = API.YML.Path.escapedName(withPathSource: pathSource)
            var queries: [[String : Any]] = []
            
            try pathType.forEach({ (typeName, path) in
                var query: [String : Any] = [
                    "uppercased_type" : typeName.uppercased(),
                    "lowercased_type" : typeName.lowercased(),
                    "name" : name,
                    "description" : path.summary
                ]
                
                var parameters: [(String, String)] = []
                var pathSource = pathSource
                var queryParameters: [String] = []
                
                try path.parameters?.forEach({ parameter in
                    let error = RuntimeError.message("Unsupported type of query parameter: \(parameter.name) for \(typeName.uppercaseFirstLetter()) in \(pathSource)")
                    guard let type = parameter.schema.expandedTypeWithSchema().0
                    else {
                        throw error
                    }
                    
                    let required = parameter.required ?? false
                    if parameter.in == "path" {
                        pathSource = pathSource.replacingOccurrences(of: "{\(parameter.name)}", with: "\\(\(parameter.name))")
                    } else if parameter.in == "query" {
                        queryParameters.append("\(parameter.name)")
                    } else {
                        throw error
                    }
                    
                    parameters.append((
                        parameter.name,
                        type + (required ? "" : "?")
                    ))
                })
                
                if let content = path.requestBody?.content {
                    guard content.count == 1
                    else {
                        throw RuntimeError.message("Multiple content types in queries not supported. \(pathSource)")
                    }
                }
                
                query["content_type"] = path.requestBody?.content?.first?.key ?? "application/json"
                
                try path.requestBody?.content?.forEach({ (contentType, parameter) in
                    let error = RuntimeError.message("Unsupported type of body parameter \(typeName.uppercaseFirstLetter()) in \(pathSource)")
                    guard let type = parameter.schema.expandedTypeWithSchema().0
                    else {
                        throw error
                    }
                    
                    let _type = type == parameter.schema.type ? type : "API.\(type)"
                    
                    parameters.append((
                        "body",
                        _type
                    ))
                })
                
                if queryParameters.count > 0 {
                    query["gquery"] = queryParameters.map({ [ "name" : $0 ] }).sorted(by: { $0["name"]! > $1["name"]! })
                }
                
                query["parameters"] = parameters.map({ ["name" : $0.0, "type" : $0.1] }).sorted(by: { $0["name"]! > $1["name"]! })
                query["init"] = parameters.map({ "\($0.0): \($0.1)" }).joined(separator: ", ")
                query["path"] = pathSource.hasPrefix("/") ? String(pathSource.dropFirst()) : pathSource
                
                try path.responses.forEach({ (code, schema) in
                    if code == "200" {
                        if let content = schema.content {
                            try content.forEach({ (key, value) in
                                let error = RuntimeError.message("Unsupported type of response: \(key) for \(typeName.uppercaseFirstLetter()) in \(pathSource)")
                                switch key {
                                case "application/json":
                                    guard let responseType = value.schema.expandedTypeWithSchema().0
                                    else {
                                        throw error
                                    }
                                    let l = "API.\(responseType)"
                                    query["response_type"] = l
                                    
                                    if l == "API.String" {
                                        print("")
                                    }
                                default: throw error
                                }
                            })
                        } else {
                            query["response_type"] = "Empty"
                        }
                    }
                })
                
                queries.append(query)
            })
            
            queries.sort(by: { (l, r) in
                guard let _l = l["lowercased_type"] as? String,
                      let _r = r["lowercased_type"] as? String
                else {
                    return false
                }
                return _l < _r
            })
            
            let  data: [AnyHashable : Any] = [
                "queries" : queries
            ]
            
            try render(
                templatesURL: templatesURL.appendingPathComponent("Query.swift"),
                outputURL: outputURL.appendingPathComponent("Sources/Queries/\(name).swift"),
                data: data
            )
        })
        
        try fileManager.createDirectory(at: outputURL.appendingPathComponent("Sources/Queries"), withIntermediateDirectories: true, attributes: nil)
    }
    
    private func render(templatesURL: URL, outputURL: URL, data: Any?) throws {
        let template = try Mustache.Template(URL: templatesURL)
        let rendered = try template.render(data)
        try rendered.write(to: outputURL, atomically: false, encoding: .utf8)
    }
}
