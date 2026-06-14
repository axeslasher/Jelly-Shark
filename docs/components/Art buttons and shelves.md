## Goal:
Create reusable and composable components for shelf items (buttons that use ArtworkImage in a variety of scenarios) and content shelves to be used in Jelly Shark. 

### Current state: 
Right now, we have the ArtworkImage.swift component that can display content images from the jellyfin server, and is used in shelf-like displays on HomeView.swift, but there are a few issues:
1. In all views we use ArtWorkImage, we get unexpected behavior counter to tvOS expectations. Focusing on an item causes the image to grow _inside_ its container. Standard tvos conventions are for the artwork itself to grow, while text (captions, titles etc) elegantly move out of the way instead of being occluded. 
2. Our 'shelves' are custom created in views that use them, and suffer from similar clipping issues. We should be able to make a shelf component with composable options that can adapt to content types we want to put on these shelves. 
3. Current strategies will get in our way in the future when we want to introduce user customization that would allow the user to choose the size of content items in shelves as a configurable option. 

### Sample Code
The following bits of code are from Apple, that may help us revise our strategy. This sample code produces the results desired to fix our issues, and could be used as a guide for revising our own code. 

#### Borderless button lockup
This example is of a landscape item, but the general idea is artwork as a button, text below. We have something similar but it behaves poorly. 
```swift
Button {} label: {
    Image("discovery_landscape") //we'd be getting our images from our jellyfinkit methods
        .resizable()
        .frame(width: 250, height: 375) //could use aspect ratio instead of explicit heights
    Text("Borderless Portrait") //We'd want to keep our two line convention we have (title/year on movies, Show title/episode title on series.)
}
.buttonStyle(.borderless)
```

#### Card Button
This example is interesting due to the amount of information shown and wrapping all of the information in the card button style. 
```swift
ScrollView(.horizontal) {
    LazyHStack(spacing: 48) {
        ForEach(Asset.allCases) { asset in
            Button {} label: {
                HStack(alignment: .top, spacing: 10) {
                    asset.landscapeImage
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading) {
                        Text(asset.title)
                            .font(.body)
                        Text("Subtitle text goes here, limited to two lines")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        HStack(spacing: 4) {
                            ForEach(1..<4) { _ in
                                Image(systemName: "ellipsis.rectangle.fill")
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .padding([.leading, .top, .bottom], 12)
                .padding(.trailing, 20)
                .frame(maxWidth: .infinity)
            }
            .containerRelativeFrame(.horizontal, count: 3, spacing: 48)
        }
    }
}
.scrollClipDisabled()
.buttonStyle(.card)
```

#### Standard content shelf
An example of a standard content shelf that displays items in a row with desired tvOS interactions
```swift
ScrollView(.horizontal) {
    LazyHStack(spacing: 40) {
        ForEach(Asset.allCases) { asset in
            Button {} label: {
                asset.portraitImage
                    .resizable()
                    .aspectRatio(250/375, contentMode: .fit)
                    .containerRelativeFrame(.horizontal, count: 6, spacing: 40)
                Text(asset.title)
            }
        }
    }
}
.scrollClipDisabled()
.buttonStyle(.borderless)
```

#### Landing Page
A sample landing page that uses background image, nice animation on scroll visibility change, and sections for content shelves
```swift
ScrollView(.vertical) {
    LazyVStack(alignment: .leading, spacing: 26) {
        VStack(alignment: .leading) {
            Text("tvOS with SwiftUI")
                .font(.largeTitle).bold()

            Spacer(minLength: 300)

            HStack {
                Button("Show") {}
                Button(“More Info…”) {}
                Spacer()
            }
            .padding(.bottom, 100)

            Spacer()
        }
        .onScrollVisibilityChange { visible in
            withAnimation {
                belowFold = !visible
            }
        }

        Section("Movie Shelf") {
            MovieShelf()
        }

        Section("TV and Music Shelf") {
            TVMusicShelf()
        }

        Section("Content Cards") {
            CardShelf()
        }
    }
    .scrollTargetLayout()
}
.scrollClipDisabled()
.background(alignment: .top) {
    if !belowFold {
        Image("beach_landscape")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .ignoresSafeArea()
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.45),
                    .init(color: .black.opacity(0), location: 0.8)
                ], startPoint: .top, endPoint: .bottom)
            }
    }
}
.scrollTargetBehavior(.viewAligned)
```

## Desired outcomes
1. Fix our current clipping issues. 
2. Use the apple sample code as a guide for revising our code, while respecting the design system theming we have already implemented. 
3. A nice beginning to content button and shelves that we can expand upon the future. 
4. Our current home page takes lesson from the example apple landing page. 