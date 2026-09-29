/*
 Adapted from KMLParser.h by Apple Inc.
 
 Abstract:
 Implements a limited KML parser.
      The following KML types are supported:
              Style,
              LineString,
              Point,
              Placemark.
           All other types are ignored
*/

@import MapKit;

@class KMLPlacemark;
@class KMLStyle;
@class KMLStyleMap;

// Parse on one owning thread, then hand off to the main thread for MapKit use.
// Do not parse/mutate concurrently with reads. Create renderers on the main thread.
NS_ASSUME_NONNULL_BEGIN

@interface KMLParser : NSObject <NSXMLParserDelegate> {
    NSMutableArray *_placemarks;
    
    KMLPlacemark *_placemark;
    KMLStyle *_style;
    
    NSXMLParser *_xmlParser;
    
    // Existing ivars (_placemark, _style, etc.)
    KMLStyleMap *_styleMap;
    
    // For parsing Pair elements inside a StyleMap:
    BOOL _inPair;
    BOOL _inPairKey;
    BOOL _inPairStyleUrl;
    NSMutableString *_pairKey;
    NSMutableString *_pairStyleUrl;
}

- (instancetype)initWithData:(NSData *)data;
// Local file only. Consumed synchronously by parseKML; no full-file NSData.
- (instancetype)initWithContentsOfURL:(NSURL *)fileURL;
// Set before parseKML. Defaults to YES for compatibility. CATA sets NO because
// RouteDetails is its authoritative stop source and it never adds KML points.
@property (nonatomic) BOOL includesPointAnnotations;
- (void)parseKML;
// Idempotent. A failed document produces no partial route geometry.
@property (nonatomic, strong, readonly, nullable) NSError *parseError;
@property (nonatomic, readonly) NSUInteger coordinateCount;

// Borrowed getters backed by strong ivars: keep the parser alive while borrowing.
// Immutable, cached render overlays; same-style line segments share an overlay.
// Point membership is also immutable and cached after parsing.
@property (unsafe_unretained, nonatomic, readonly) NSArray<id<MKOverlay>> *overlays;
@property (unsafe_unretained, nonatomic, readonly) NSArray<id<MKAnnotation>> *points;
// Live parser-owned storage; mutate only under the parser's confinement.
@property (nonatomic, strong, nullable) NSMutableDictionary *styles;

- (nullable MKOverlayRenderer *)rendererForOverlay:(id <MKOverlay>)overlay;

@end

@interface KMLElement : NSObject {
    NSString *identifier;
    NSMutableString *accum;
}

- (instancetype)initWithIdentifier:(nullable NSString *)ident;

@property (nonatomic, strong, readonly, nullable) NSString *identifier;

// Returns YES if we're currently parsing an element that has character
// data contents that we are interested in saving.
@property (NS_NONATOMIC_IOSONLY, readonly) BOOL canAddString;

// Add character data parsed from the xml
- (void)addString:(NSString *)str;

@end


// Represents a KML <Style> element.  <Style> elements may either be specified
// at the top level of the KML document with identifiers or they may be
// specified anonymously within a Geometry element.
@interface KMLStyle : KMLElement {
    UIColor *strokeColor;
    CGFloat strokeWidth;
    
    BOOL stroke;
    
    struct {
        int inLineStyle:1;
        
        int inColor:1;
        int inWidth:1;
        int inOutline:1;
    } flags;
}

@property (unsafe_unretained, nonatomic, readonly, nullable) UIColor *strokeColor;

- (void)beginLineStyle;
- (void)endLineStyle;

- (void)beginColor;
- (void)endColor;

- (void)beginWidth;
- (void)endWidth;

- (void)beginOutline;
- (void)endOutline;

- (void)applyToOverlayPathRenderer:(MKOverlayPathRenderer *)renderer;

@end

NS_ASSUME_NONNULL_END
