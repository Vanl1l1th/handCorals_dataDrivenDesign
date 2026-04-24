/**
 * ReefViewer.pde
 *
 * Reads reef_coral_species_matching.json from the sketch folder.
 * Shows one reef at a time with:
 *   - The dominant polygon outline
 *   - MIN_CORAL_COUNT point clouds (one per coral species), masked to the polygon,
 *     coloured from each species' colour texture and depth image.
 *   - A live depth threshold: points whose normalised depth >= threshold keep
 *     their texture colour; deeper points turn black.
 *
 * Expected folder layout (all next to the .pde file):
 *   reef_coral_species_matching.json
 *   hand_images_depth/hand_image_XXXX_00001_.png
 *   colorTextures/<Species Name>_00001_.png
 *
 *  Controls
 *  --------
 *  1            -> next reef
 *  2            -> raise depth threshold (fewer coloured points)
 *  3            -> lower depth threshold (more coloured points)
 *  Left-drag    -> orbit   |  Right-drag -> pan
 *  Scroll       -> zoom    |  Double-click -> reset camera
 */

import peasy.*;

// ── Constants ──────────────────────────────────────────────────────────────

final float POLY_SIZE       = 800.0;   // dominant polygon longest axis (Processing units)
final float MAX_Z           = 100.0;    // maximum Z lift from depth map
final int   SAMPLE_STEP     = 5;       // sample every Nth pixel per depth image
final int   MIN_CORAL_COUNT = 10;       // species clouds to build per reef
final float THRESHOLD_STEP  = 0.05;   // how much '2'/'3' moves the threshold

// ── Global state ───────────────────────────────────────────────────────────

PeasyCam          cam;
ArrayList<Reef>   reefs          = new ArrayList<Reef>();
int               reefIdx        = 0;
float             depthThreshold = 0.5;  // 0 (all coloured) .. 1 (only peak coloured)

// Cache: depth-image filename (no path) -> loaded PImage
HashMap<String, PImage> depthCache = new HashMap<String, PImage>();

// ── Data structures ────────────────────────────────────────────────────────

class ReefPolygon {
  float[][][] rings;
  float centerLon, centerLat, scale;
}

class CoralSpecies {
  String name, depthPath, colorPath;
}

class CoralCloud {
  String   speciesName;
  PVector[] pts;   // x,y = polygon space;  z = brightness * MAX_Z
  color[]   cols;  // colour-texture colour at the same UV as depth sample
}

class Reef {
  int     id;
  String  benthic, geomorphic;
  ArrayList<ReefPolygon>  polygons = new ArrayList<ReefPolygon>();
  ArrayList<CoralSpecies> species  = new ArrayList<CoralSpecies>();
  ArrayList<CoralCloud>   clouds   = new ArrayList<CoralCloud>();
  boolean cloudsBuilt = false;
}

// ── Setup ──────────────────────────────────────────────────────────────────

void setup() {
  size(1000, 750, P3D);
  smooth(8);
  cam = new PeasyCam(this, 900);
  loadReefs();
  buildClouds(reefs.get(reefIdx));
}

// ── Draw ───────────────────────────────────────────────────────────────────

void draw() {
  background(8, 18, 38);
  Reef reef = reefs.get(reefIdx);
  //drawGrid();
  //drawAxes();
  for (CoralCloud cloud : reef.clouds) drawCloud(cloud);
  cam.beginHUD();
    drawHUD(reef);
  cam.endHUD();
}

// ── Input ──────────────────────────────────────────────────────────────────

void keyPressed() {
  if (key == '1') {
    reefIdx = (reefIdx + 1) % reefs.size();
    buildClouds(reefs.get(reefIdx));
    cam.reset();
  }
  if (key == '2') depthThreshold = min(1.0 + THRESHOLD_STEP, depthThreshold + THRESHOLD_STEP);
  if (key == '3') depthThreshold = max(0.0, depthThreshold - THRESHOLD_STEP);
}

// ── JSON loading ───────────────────────────────────────────────────────────

void loadReefs() {
  JSONObject root      = loadJSONObject(sketchPath("reef_coral_species_matching.json"));
  JSONArray  reefArray = root.getJSONArray("reefs");

  for (int i = 0; i < reefArray.size(); i++) {
    JSONObject ro   = reefArray.getJSONObject(i);
    Reef       reef = new Reef();
    reef.id         = ro.getInt("reef_id");
    reef.benthic    = ro.getString("benthic_class");
    reef.geomorphic = ro.getString("geomorphic_class");

    // Parse species list
    JSONArray spArray = ro.getJSONArray("potential_coral_species");
    int spCount = min(max(MIN_CORAL_COUNT, MIN_CORAL_COUNT), spArray.size());
    for (int s = 0; s < spCount; s++) {
      JSONObject    so  = spArray.getJSONObject(s);
      CoralSpecies  sp  = new CoralSpecies();
      sp.name           = so.getString("species_name");
      String handFile   = so.getString("hand_image_filename");
      String handBase   = handFile.substring(0, handFile.lastIndexOf('.'));
      sp.depthPath      = "hand_images_depth/" + handBase + "_00001_.png";
      sp.colorPath      = "colorTextures/" + sp.name + "_00001_.png";
      reef.species.add(sp);
    }

    // Parse polygons
    JSONArray polygonArray = ro.getJSONArray("polygons");
    for (int j = 0; j < polygonArray.size(); j++) {
      JSONObject  polyObj    = polygonArray.getJSONObject(j);
      JSONArray   ringsArray = polyObj.getJSONArray("coordinates");
      ReefPolygon poly       = new ReefPolygon();
      poly.rings = new float[ringsArray.size()][][];
      for (int r = 0; r < ringsArray.size(); r++) {
        JSONArray ring = ringsArray.getJSONArray(r);
        poly.rings[r]  = new float[ring.size()][2];
        for (int p = 0; p < ring.size(); p++) {
          JSONArray pt        = ring.getJSONArray(p);
          poly.rings[r][p][0] = pt.getFloat(0);
          poly.rings[r][p][1] = pt.getFloat(1);
        }
      }
      computePolyNorm(poly);
      reef.polygons.add(poly);
    }
    reefs.add(reef);
  }
  println("Loaded " + reefs.size() + " reefs.");
}

// ── Polygon helpers ────────────────────────────────────────────────────────

void computePolyNorm(ReefPolygon poly) {
  float lonMin =  1e9, lonMax = -1e9;
  float latMin =  1e9, latMax = -1e9;
  for (float[][] ring : poly.rings)
    for (float[] pt : ring) {
      if (pt[0] < lonMin) lonMin = pt[0];  if (pt[0] > lonMax) lonMax = pt[0];
      if (pt[1] < latMin) latMin = pt[1];  if (pt[1] > latMax) latMax = pt[1];
    }
  poly.centerLon = (lonMin + lonMax) * 0.5;
  poly.centerLat = (latMin + latMax) * 0.5;
  float range    = max(lonMax - lonMin, latMax - latMin);
  poly.scale     = (range > 0) ? POLY_SIZE / range : 50000.0;
}

float mx(float lon, ReefPolygon p) { return  (lon - p.centerLon) * p.scale; }
float my(float lat, ReefPolygon p) { return -(lat - p.centerLat) * p.scale; }

int vertexCount(ReefPolygon poly) {
  int n = 0; for (float[][] r : poly.rings) n += r.length; return n;
}

ReefPolygon dominantPoly(Reef reef) {
  ReefPolygon best = reef.polygons.get(0);
  for (int i = 1; i < reef.polygons.size(); i++) {
    ReefPolygon c = reef.polygons.get(i);
    if (vertexCount(c) > vertexCount(best)) best = c;
  }
  return best;
}

boolean pointInPolygon(float px, float py, float[] rx, float[] ry) {
  int n = rx.length; boolean in = false;
  for (int i = 0, j = n - 1; i < n; j = i++) {
    if (((ry[i] > py) != (ry[j] > py)) &&
        (px < (rx[j] - rx[i]) * (py - ry[i]) / (ry[j] - ry[i]) + rx[i]))
      in = !in;
  }
  return in;
}

// ── Cloud building ─────────────────────────────────────────────────────────

void buildClouds(Reef reef) {
  if (reef.cloudsBuilt) return;
  reef.clouds.clear();
  println("Building " + reef.species.size() + " clouds for reef " + reef.id);

  ReefPolygon poly = dominantPoly(reef);

  // Bounding box in Processing space
  float xMin =  1e9, xMax = -1e9, yMin =  1e9, yMax = -1e9;
  for (float[] pt : poly.rings[0]) {
    float px = mx(pt[0], poly), py = my(pt[1], poly);
    if (px < xMin) xMin = px;  if (px > xMax) xMax = px;
    if (py < yMin) yMin = py;  if (py > yMax) yMax = py;
  }

  // Outer ring in Processing space for point-in-polygon test
  float[] ringX = new float[poly.rings[0].length];
  float[] ringY = new float[poly.rings[0].length];
  for (int i = 0; i < poly.rings[0].length; i++) {
    ringX[i] = mx(poly.rings[0][i][0], poly);
    ringY[i] = my(poly.rings[0][i][1], poly);
  }

  for (CoralSpecies sp : reef.species) {
    // ── Load (or retrieve cached) depth image ────────────────────────────
    String depthKey = sp.depthPath;
    PImage depthImg = depthCache.get(depthKey);
    if (depthImg == null) {
      depthImg = loadImage(sketchPath(sp.depthPath));
      if (depthImg == null) { println("  !! depth missing: " + sp.depthPath); continue; }
      depthCache.put(depthKey, depthImg);
    }

    // ── Load colour texture ───────────────────────────────────────────────
    PImage colorImg = loadImage(sketchPath(sp.colorPath));
    if (colorImg == null) { println("  !! colour missing: " + sp.colorPath); continue; }
    colorImg.resize(depthImg.width, depthImg.height);

    depthImg.loadPixels();
    colorImg.loadPixels();

    int W = depthImg.width, H = depthImg.height;

    ArrayList<PVector> ptList  = new ArrayList<PVector>();
    ArrayList<Integer> colList = new ArrayList<Integer>();

    for (int py = 0; py < H; py += SAMPLE_STEP) {
      for (int px = 0; px < W; px += SAMPLE_STEP) {
        float x = map(px, 0, W - 1, xMin, xMax);
        float y = map(py, 0, H - 1, yMin, yMax);

        if (!pointInPolygon(x, y, ringX, ringY)) continue;

        int   idx = py * W + px;
        float b   = constrain(brightness(depthImg.pixels[idx]) / 100.0, 0.0, 1.0);
        float z   = b * MAX_Z;

        ptList.add(new PVector(x, y, z));
        colList.add(colorImg.pixels[idx]);
      }
    }

    CoralCloud cloud = new CoralCloud();
    cloud.speciesName = sp.name;
    cloud.pts  = ptList.toArray(new PVector[0]);
    cloud.cols = new color[colList.size()];
    for (int i = 0; i < colList.size(); i++) cloud.cols[i] = colList.get(i);
    reef.clouds.add(cloud);
    println("  " + sp.name + " -> " + cloud.pts.length + " pts");
  }

  reef.cloudsBuilt = true;
}

// ── Rendering ──────────────────────────────────────────────────────────────

void drawGrid() {
  pushStyle(); strokeWeight(0.4); stroke(25, 60, 95, 130); noFill();
  float half = POLY_SIZE, step = half * 2.0 / 10.0;
  for (int i = 0; i <= 10; i++) {
    float t = -half + i * step;
    line(t, -half, 0,  t,  half, 0);
    line(-half, t, 0,  half, t, 0);
  }
  popStyle();
}

void drawAxes() {
  pushStyle(); strokeWeight(1.5); float len = 60;
  stroke(255,  80,  80);  line(0,0,0,  len,   0, 0);
  stroke( 80, 255,  80);  line(0,0,0,    0, -len, 0);
  stroke( 80, 120, 255);  line(0,0,0,    0,   0, len);
  popStyle();
}


void drawCloud(CoralCloud cloud) {
  pushStyle();
  strokeWeight(3);
  noFill();
  for (int i = 0; i < cloud.pts.length; i++) {
    PVector pt       = cloud.pts[i];
    float   depthVal = pt.z / MAX_Z;               // normalised 0..1
    // Points at or above the threshold keep their texture colour;
    // deeper points go black so the threshold "peels" the surface.
    color c = (depthVal > depthThreshold) ? cloud.cols[i] : color(0,0,0,0.5);
    stroke(c);
    //fill(c);
    point(pt.x, pt.y, pt.z);
  }
  popStyle();
}

// ── HUD ────────────────────────────────────────────────────────────────────

void drawHUD(Reef reef) {
  textAlign(LEFT, TOP);

  // ── Main info card ───────────────────────────────────────────────────────
  noStroke();
  fill(0, 0, 0, 175);
  rect(10, 10, 390, 120, 7);

  fill(255, 255, 255, 235);
  textSize(15);
  text("Reef #" + reef.id + "   (" + (reefIdx + 1) + " / " + reefs.size() + ")", 20, 18);

  fill(200, 220, 255, 215);
  textSize(11);
  text("Benthic:    " + reef.benthic,    20, 42);
  text("Geomorphic: " + reef.geomorphic, 20, 58);

  int totalPts = 0;
  for (CoralCloud c : reef.clouds) totalPts += c.pts.length;
  text("Species shown: " + reef.clouds.size()
     + "   Total pts: " + totalPts, 20, 74);

  // ── Depth threshold bar ──────────────────────────────────────────────────
  fill(140, 170, 140, 185);
  textSize(10);
  text("Depth threshold: " + nf(depthThreshold, 1, 2)
     + "   (2 = raise / 3 = lower)", 20, 92);

  // visual bar
  float barX = 20, barY = 106, barW = 355, barH = 10;
  noStroke(); fill(40, 40, 60, 200);
  rect(barX, barY, barW, barH, 3);
  fill(0, 200, 255, 200);
  rect(barX, barY, barW * constrain(1.0 - depthThreshold, 0, 1), barH, 3);  // coloured fraction
  fill(255, 80, 80, 220);
  float markerX = barX + barW * depthThreshold;
  rect(markerX - 1, barY - 2, 2, barH + 4);

  // ── Species list ─────────────────────────────────────────────────────────
  int listH = 20 + reef.clouds.size() * 16 + 8;
  fill(0, 0, 0, 175);
  rect(10, 140, 280, listH, 7);
  fill(255, 255, 255, 200);
  textSize(11);
  text("Coral species:", 20, 146);
  for (int i = 0; i < reef.clouds.size(); i++) {
    fill(180, 220, 255, 200);
    textSize(10);
    text((i + 1) + ". " + reef.clouds.get(i).speciesName, 20, 162 + i * 16);
  }

  // ── Controls bar ─────────────────────────────────────────────────────────
  fill(0, 0, 0, 165);
  rect(10, height - 38, 560, 26, 6);
  fill(160, 200, 255, 210);
  textSize(11);
  textAlign(LEFT, CENTER);
  text("1: next reef   2: threshold ↑   3: threshold ↓   Left-drag: orbit   Scroll: zoom   Dbl-click: reset",
       20, height - 25);
}

// ── Colour helpers ─────────────────────────────────────────────────────────

color reefFill(String b) {
  switch(b) {
    case "Coral/Algae": return color(  0,160,220);
    case "Rock":        return color(130,130,150);
    case "Seagrass":    return color( 50,200, 80);
    case "Sand":        return color(230,210,110);
    case "Rubble":      return color(200,130, 60);
    default:            return color(180,180,180);
  }
}
color reefStroke(String b) {
  switch(b) {
    case "Coral/Algae": return color(  0,210,255);
    case "Rock":        return color(190,190,205);
    case "Seagrass":    return color( 80,255,100);
    case "Sand":        return color(255,240,150);
    case "Rubble":      return color(255,170, 80);
    default:            return color(220,220,220);
  }
}
color adjustAlpha(color c, int a) { return color(red(c),green(c),blue(c),a); }
color dimColor(color c, float f)  { return color(red(c)*f,green(c)*f,blue(c)*f); }
